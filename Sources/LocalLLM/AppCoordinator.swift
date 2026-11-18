import Foundation
import AppKit

/// Wires every subsystem together and owns the process lifecycle (start, hot-reload,
/// blue/green hand-off, shutdown).
final class AppCoordinator {
    static let shared = AppCoordinator()

    let config = ConfigStore()
    /// Local + remote LLM providers (providers.json, hot-reloaded; editable from the dashboard).
    let providers = ProviderStore()
    let hardware: HardwareInfo
    private let planBox: Locked<ModelPlan>
    let memory: MemoryMonitor
    let tracker: TokenTracker
    let admission: AdmissionController
    private(set) var ollama: OllamaProcessManager!
    private(set) var gateway: InferenceGateway!
    private(set) var updater: GitAutoUpdater!

    private(set) var mode: RunMode = .app
    private let startedAt = Date()
    private var signalSources: [DispatchSourceSignal] = []
    private var handoffContinuation: CheckedContinuation<Bool, Never>?
    private let handoffLock = NSLock()
    private var shuttingDown = false
    private var pendingPurge = false

    var plan: ModelPlan { planBox.get() }
    /// Model the user picked in the menu bar / dashboard (nil = automatic by hardware profile).
    private let overrideBox = Locked<String?>(AppCoordinator.loadOverride())
    var modelOverride: String? { overrideBox.get() }
    /// The model the profiler chose before any manual override.
    private let autoModelBox = Locked<String>("")
    var autoModel: String { autoModelBox.get() }

    private static func loadOverride() -> String? {
        guard let d = try? Data(contentsOf: AppPaths.modelOverride), let o = JSON.object(d) else { return nil }
        return (o["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Profiler selection + manual model override.
    private func computePlan(_ cfg: RemoteConfig) -> ModelPlan {
        var p = HardwareProfiler.select(hardware: hardware, config: cfg)
        autoModelBox.set(p.model)
        if let o = overrideBox.get(), ProcessInfo.processInfo.environment["LOCALLLM_FORCE_MODEL"] == nil {
            p.adjustments.append("Modelo elegido manualmente: \(o) (automático sería \(p.model))")
            p.model = o
        }
        return p
    }

    private init() {
        hardware = HardwareProfiler.detect()
        var p = HardwareProfiler.select(hardware: hardware, config: config.current)
        autoModelBox.set(p.model)
        if let o = overrideBox.get(), ProcessInfo.processInfo.environment["LOCALLLM_FORCE_MODEL"] == nil {
            p.adjustments.append("Modelo elegido manualmente: \(o) (automático sería \(p.model))")
            p.model = o
        }
        planBox = Locked(p)
        memory = MemoryMonitor(config: config.current.memoryGuard)
        let isHealthCheck = CommandLine.arguments.contains("--health-check")
        tracker = TokenTracker(readOnly: isHealthCheck)
        admission = AdmissionController(capacity: p.numParallel, maxQueue: config.current.gateway.maxQueueDepth)
        ollama = OllamaProcessManager(plan: p, config: config.current.ollama)
        gateway = InferenceGateway(app: self)
        updater = GitAutoUpdater(app: self)
        Log.info("profiler", "Hardware: \(hardware.summary) GPU cores=\(hardware.gpuCores.map(String.init) ?? "?") -> \(p.profileId) / \(p.model) ctx=\(p.numCtx) parallel=\(p.numParallel)")
        p.adjustments.forEach { Log.info("profiler", "adjustment: \($0)") }
    }

    // MARK: Start

    func start(mode: RunMode) async {
        self.mode = mode
        let cfg = config.current
        memory.update(threshold: plan.minFreeBytes, config: cfg.memoryGuard)
        memory.onBreakerChange = { [weak self] open, snap in self?.breakerChanged(open: open, snapshot: snap) }
        admission.onIdle = { [weak self] in self?.idleReached() }
        memory.start()

        let port: Int
        if case .healthCheck(let p) = mode { port = p } else { port = Int(ProcessInfo.processInfo.environment["LOCALLLM_PORT"] ?? "") ?? cfg.gateway.port }
        do {
            try gateway.start(host: cfg.gateway.host, port: port)
        } catch {
            Log.error("gateway", "Cannot bind \(cfg.gateway.host):\(port): \(error)")
            if mode != .app { exit(3) }
            return
        }
        if case .healthCheck = mode { return }   // candidate self-test: gateway + config + profiler only

        installSignalHandlers()
        await ollama.start()

        // Blue/green: tell the previous instance we're serving so it can drain and exit.
        if ProcessInfo.processInfo.environment["LOCALLLM_TAKEOVER"] == "1",
           let parent = Int32(ProcessInfo.processInfo.environment["LOCALLLM_PARENT_PID"] ?? "") {
            Log.info("handoff", "New instance ready; signalling previous instance pid \(parent)")
            kill(parent, SIGUSR1)
        }
        if ProcessInfo.processInfo.environment["LOCALLLM_DISABLE_UPDATER"] != "1" { updater.start() }
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGUSR1] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                guard let self else { return }
                if sig == SIGUSR1 {
                    self.handoffLock.lock()
                    let c = self.handoffContinuation
                    self.handoffContinuation = nil
                    self.handoffLock.unlock()
                    c?.resume(returning: true)
                } else {
                    Task { await self.shutdown(handoff: false); exit(0) }
                }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: Memory guard actions

    private func breakerChanged(open: Bool, snapshot: MemorySnapshot) {
        tracker.incident(open ? "memory-breaker-open" : "memory-breaker-closed",
                         String(format: "available=%.2fGiB threshold=%.2fGiB pressure=%@ swap=%.2fGiB",
                                gib(snapshot.availableBytes), gib(snapshot.thresholdBytes), snapshot.pressure, gib(snapshot.swapUsedBytes)))
        guard open, config.current.memoryGuard.purgeIdleModelOnPressure else { return }
        if admission.stats.inFlight == 0 {
            Task { await ollama.unloadModels(); gateway.contextPolicy.forget() }
        } else {
            pendingPurge = true   // purge as soon as the in-flight generations finish
        }
    }

    private func idleReached() {
        guard pendingPurge, memory.isBreakerOpen else { pendingPurge = false; return }
        pendingPurge = false
        Task { await ollama.unloadModels(); gateway.contextPolicy.forget() }
    }

    // MARK: Routing

    func resolveModel(_ requested: String?) -> String {
        let auto = plan.model
        guard let req = requested?.trimmingCharacters(in: .whitespaces), !req.isEmpty else { return auto }
        let routing = config.current.routing
        if let target = routing.aliases[req] { return target == "$auto" ? auto : target }
        if req == auto || req + ":latest" == auto { return auto }
        if routing.passthroughInstalledModels {
            let installed = ollama.installedModels
            if installed[req] != nil || installed[req + ":latest"] != nil { return req }
        }
        return auto
    }

    /// Local Ollama model or a remote provider (Claude, ChatGPT, LocalIA…) for a requested model name.
    func route(_ requested: String?) -> ModelRoute {
        providers.route(requested, aliases: config.current.routing.aliases, local: { self.resolveModel($0) })
    }

    // MARK: Manual model selection

    /// Sets (or clears with nil) the manual model. Pulls it if needed, then loads it in Metal.
    func setModel(_ model: String?) async -> (ok: Bool, detail: String) {
        let m = model?.trimmingCharacters(in: .whitespaces)
        let value = (m?.isEmpty ?? true) ? nil : m
        if let v = value, ollama.installedModels[v] == nil, ollama.installedModels[v + ":latest"] == nil,
           !config.current.ollama.autoPull {
            return (false, "\(v) no está instalado y autoPull está desactivado")
        }
        overrideBox.set(value)
        if let v = value {
            try? JSONSerialization.data(withJSONObject: ["model": v]).write(to: AppPaths.modelOverride, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: AppPaths.modelOverride)
        }
        let cfg = config.current
        let newPlan = computePlan(cfg)
        planBox.set(newPlan)
        tracker.incident("model-selected", value.map { "manual: \($0)" } ?? "automático: \(newPlan.model)")
        let admission = self.admission
        Task { await ollama.apply(plan: newPlan, config: cfg.ollama, admission: admission, drainTimeout: cfg.gateway.drainTimeoutSeconds) }
        return (true, "modelo activo: \(newPlan.model)")
    }

    func modelsPayload() -> [String: Any] {
        let installed = ollama.installedModels.sorted { $0.key < $1.key }.map { ["name": $0.key, "sizeBytes": $0.value] as [String: Any] }
        return [
            "active": plan.model,
            "auto": autoModel,
            "override": modelOverride ?? NSNull(),
            "installed": installed,
            "loaded": JSON.dictionary(ollama.loadedModels),
            "lastUsed": tracker.liveStats.lastModel ?? NSNull(),
            "engine": ollama.status.label
        ]
    }

    // MARK: Hot reload (Level 1)

    func reloadConfig(reason: String) async -> (ok: Bool, detail: String) {
        let old: RemoteConfig, new: RemoteConfig
        do { (old, new) = try config.reload() } catch {
            tracker.incident("config-reload-rejected", "\(reason): \(error.localizedDescription)")
            return (false, error.localizedDescription)
        }
        let oldPlan = plan
        let newPlan = computePlan(new)
        planBox.set(newPlan)
        memory.update(threshold: newPlan.minFreeBytes, config: new.memoryGuard)
        admission.configure(capacity: newPlan.numParallel, maxQueue: new.gateway.maxQueueDepth)
        if old.updater != new.updater { updater.reschedule() }
        var changes: [String] = []
        if oldPlan != newPlan { changes.append("plan \(oldPlan.model)/ctx\(oldPlan.numCtx)/p\(oldPlan.numParallel) -> \(newPlan.model)/ctx\(newPlan.numCtx)/p\(newPlan.numParallel)") }
        if old.gateway.port != new.gateway.port || old.gateway.host != new.gateway.host {
            changes.append("gateway address change takes effect on next restart")
        }
        if oldPlan != newPlan || old.ollama != new.ollama {
            let drain = new.gateway.drainTimeoutSeconds
            Task { await ollama.apply(plan: newPlan, config: new.ollama, admission: admission, drainTimeout: drain) }
        }
        let detail = changes.isEmpty ? "configuration reloaded (\(reason)); no engine changes" : changes.joined(separator: "; ")
        Log.info("config", detail)
        return (true, detail)
    }

    // MARK: Blue/green restart (Level 2)

    /// Spawns the new binary (it binds the same port via SO_REUSEPORT and adopts the running
    /// Ollama), waits for its SIGUSR1 "ready", then drains in-flight requests and exits.
    func performBlueGreenRestart(binary: URL, commit: String, version: String? = nil) async -> Bool {
        guard mode == .app || mode == .headless else { return false }
        var env: [String: String] = [
            "LOCALLLM_TAKEOVER": "1",
            "LOCALLLM_PARENT_PID": String(getpid()),
            "LOCALLLM_COMMIT": commit,
            "LOCALLLM_REDIRECTED": "1",
        ]
        if let version { env["LOCALLLM_VERSION"] = version }
        if let b = AppEnvironment.appBundleURL { env["LOCALLLM_APP_BUNDLE"] = b.path }
        if let r = AppEnvironment.resourcesURL { env["LOCALLLM_RESOURCES"] = r.path }

        // Menu bar app + bundled build: open it through LaunchServices (a plain child process
        // would run without a menu bar icon). Headless or loose binaries keep using Process.
        let bundle = mode == .app ? BundleLauncher.bundle(containing: binary) : nil
        var child: Process?
        var childApp: NSRunningApplication?
        var childPid: Int32 = 0

        let ready: Bool = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            handoffLock.lock(); handoffContinuation = c; handoffLock.unlock()
            let failStart = {
                self.handoffLock.lock(); self.handoffContinuation = nil; self.handoffLock.unlock()
                c.resume(returning: false)
            }
            if let bundle {
                guard let app = BundleLauncher.open(bundle: bundle, environment: env,
                                                    arguments: mode == .headless ? ["--headless"] : []) else { failStart(); return }
                childApp = app
                childPid = app.processIdentifier
            } else {
                let p = Process()
                p.executableURL = binary
                p.arguments = mode == .headless ? ["--headless"] : []
                var full = ProcessInfo.processInfo.environment
                env.forEach { full[$0.key] = $0.value }
                p.environment = full
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { failStart(); return }
                child = p
                childPid = p.processIdentifier
            }
            Log.info("handoff", "Started new instance pid \(childPid) (\(commit.prefix(8)))\(bundle != nil ? " via LaunchServices" : ""); waiting for ready signal")
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) { [weak self] in
                guard let self else { return }
                self.handoffLock.lock()
                let pending = self.handoffContinuation
                self.handoffContinuation = nil
                self.handoffLock.unlock()
                pending?.resume(returning: false)
            }
        }
        guard ready else {
            if let child, child.isRunning { child.terminate() }
            if let childApp, !childApp.isTerminated { childApp.forceTerminate() }
            tracker.incident("handoff-failed", "new instance \(commit.prefix(8)) did not signal ready")
            return false
        }
        tracker.incident("handoff", "new instance \(commit.prefix(8)) pid \(childPid) took over; draining")
        await shutdown(handoff: true)
        exit(0)
    }

    func shutdown(handoff: Bool) async {
        guard !shuttingDown else { return }
        shuttingDown = true
        await gateway.drain(timeout: config.current.gateway.drainTimeoutSeconds)
        await ollama.stop(detach: handoff)
        Log.info("app", handoff ? "Hand-off complete; exiting" : "Shutdown complete")
    }

    // MARK: Payloads

    func healthPayload() -> [String: Any] {
        [
            "status": "ok",
            "pid": Int(getpid()),
            "version": AppEnvironment.version,
            "commit": AppEnvironment.runningCommit,
            "uptimeSeconds": Int(Date().timeIntervalSince(startedAt)),
            "engine": ollama.status.label,
            "model": plan.model,
            "breakerOpen": memory.isBreakerOpen,
            "defaultProvider": providers.current.defaultProvider,
            "displayVersion": AppEnvironment.displayVersion
        ]
    }

    func hardwareProfilePayload() -> [String: Any] {
        let p = plan
        return [
            "hardware": JSON.dictionary(hardware),
            "selection": JSON.dictionary(p),
            "ollamaEnvironment": OllamaProcessManager.environment(plan: p, config: config.current.ollama),
            "memoryNow": JSON.dictionary(memory.snapshot),
            "loadedModels": JSON.dictionary(ollama.loadedModels),
            "configSource": config.source,
            "summary": "\(hardware.summary) -> \(p.model) (\(p.quantization)), num_ctx=\(p.numCtx), parallel=\(p.numParallel), KV=\(p.kvCacheType), budget=\(String(format: "%.2f", gib(p.metalBudgetBytes))) GiB"
        ]
    }

    func timeseriesPayload(window: String?) -> [String: Any] {
        let w = window ?? "24h"
        let (seconds, bucket): (Double, Int)
        switch w {
        case "1h": (seconds, bucket) = (3600, 60)
        case "7d": (seconds, bucket) = (7 * 86_400, 7200)
        case "30d", "all": (seconds, bucket) = (30 * 86_400, 86_400)
        default: (seconds, bucket) = (86_400, 900)
        }
        let since = Date().addingTimeInterval(-seconds)
        return ["window": w, "bucketSeconds": bucket, "from": since.timeIntervalSince1970,
                "to": Date().timeIntervalSince1970,
                "points": tracker.timeseries(since: since, bucketSeconds: bucket)]
    }

    func memoryPayload() -> [String: Any] {
        let loaded = ollama.loadedModels
        return [
            "now": JSON.dictionary(memory.snapshot),
            "history": JSON.dictionary(memory.history),
            "loadedModels": JSON.dictionary(loaded),
            "weightsBytes": loaded.reduce(UInt64(0)) { $0 + $1.weightsBytes },
            "kvCacheBytes": loaded.reduce(UInt64(0)) { $0 + $1.kvCacheBytes },
            "plan": ["model": plan.model, "budgetBytes": plan.metalBudgetBytes, "minFreeBytes": plan.minFreeBytes,
                     "estimate": JSON.dictionary(plan.estimate)] as [String: Any]
        ]
    }

    func metricsPayload(window: String?) -> [String: Any] {
        let since: Date?
        switch window ?? "all" {
        case "1h": since = Date().addingTimeInterval(-3600)
        case "24h": since = Date().addingTimeInterval(-86_400)
        case "7d": since = Date().addingTimeInterval(-7 * 86_400)
        case "30d": since = Date().addingTimeInterval(-30 * 86_400)
        case "session": since = startedAt
        default: since = nil
        }
        var m = tracker.metrics(since: since)
        let a = admission.stats
        m["window"] = window ?? "all"
        m["version"] = AppEnvironment.displayVersion
        m["generatedAt"] = ISO8601DateFormatter().string(from: Date())
        m["live"] = [
            "inFlight": a.inFlight,
            "queued": a.queued,
            "capacity": a.capacity,
            "paused": a.paused,
            "openConnections": gateway.inFlight,
            "breakerOpen": memory.isBreakerOpen,
            "model": plan.model,
            "engine": ollama.status.label,
            "session": JSON.dictionary(tracker.liveStats),
            "memory": JSON.dictionary(memory.snapshot),
            "loadedModels": JSON.dictionary(ollama.loadedModels)
        ] as [String: Any]
        return m
    }
}

// MARK: - Launcher: run the auto-updated binary if one was installed for this bundle version

enum Launcher {
    static func redirectIfUpdated() {
        let env = ProcessInfo.processInfo.environment
        guard env["LOCALLLM_REDIRECTED"] != "1", env["LOCALLLM_NO_REDIRECT"] != "1",
              let data = try? Data(contentsOf: AppPaths.currentBinaryMeta),
              let meta = JSON.object(data),
              let path = meta["path"] as? String,
              let commit = meta["commit"] as? String,
              meta["baseBundleCommit"] as? String == AppEnvironment.bundledCommit,
              FileManager.default.isExecutableFile(atPath: path),
              AppEnvironment.executableURL.path != URL(fileURLWithPath: path).resolvingSymlinksInPath().path else { return }
        // A newer .dmg install has a different bundled commit, so stale updates are ignored.
        var childEnv: [String: String] = ["LOCALLLM_REDIRECTED": "1", "LOCALLLM_COMMIT": commit]
        if let v = meta["version"] as? String { childEnv["LOCALLLM_VERSION"] = v }
        if let b = AppEnvironment.appBundleURL { childEnv["LOCALLLM_APP_BUNDLE"] = b.path }
        if let r = AppEnvironment.resourcesURL { childEnv["LOCALLLM_RESOURCES"] = r.path }

        // Updates are .app bundles opened through LaunchServices (see BundleLauncher: with execv the
        // menu bar icon never shows). Loose binaries from older updaters are wrapped on the fly.
        var exe = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if BundleLauncher.bundle(containing: exe) == nil {
            let dest = exe.deletingLastPathComponent().appendingPathComponent(exe.lastPathComponent + ".app")
            do {
                exe = try BundleLauncher.makeBundle(binary: exe, at: dest, baseBundle: AppEnvironment.appBundleURL,
                                                    version: meta["version"] as? String)
                var updated = meta
                updated["path"] = exe.path
                if let d = try? JSONSerialization.data(withJSONObject: updated) { try? d.write(to: AppPaths.currentBinaryMeta, options: .atomic) }
                Log.info("launcher", "Wrapped legacy binary into \(dest.lastPathComponent)")
            } catch {
                Log.error("launcher", "Cannot wrap \(path) into an .app: \(error.localizedDescription)")
            }
        }
        if let bundle = BundleLauncher.bundle(containing: exe),
           let app = BundleLauncher.open(bundle: bundle, environment: childEnv, arguments: Array(CommandLine.arguments.dropFirst())) {
            Log.info("launcher", "Opened auto-updated bundle \(bundle.lastPathComponent) (\(commit.prefix(8))) pid \(app.processIdentifier)")
            Log.flush()
            exit(0)
        }

        // Last resort: exec the binary in place (runs, but without a menu bar icon).
        childEnv.forEach { setenv($0.key, $0.value, 1) }
        Log.info("launcher", "Executing auto-updated binary \(exe.path) (\(commit.prefix(8)))")
        var args: [UnsafeMutablePointer<CChar>?] = ([exe.path] + CommandLine.arguments.dropFirst()).map { strdup($0) }
        args.append(nil)
        execv(exe.path, &args)
        Log.error("launcher", "execv failed (\(errno)); continuing with bundled binary")
    }
}
