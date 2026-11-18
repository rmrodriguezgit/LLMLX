import Foundation
import AppKit

/// Wires every subsystem together and owns the process lifecycle (start, hot-reload,
/// blue/green hand-off, shutdown).
final class AppCoordinator {
    static let shared = AppCoordinator()

    let config = ConfigStore()
    /// Remote OpenAI-compatible APIs configured on this Mac.
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

    /// Profiler selection + manual model override. A remote override ("openai/gpt-4o") leaves the
    /// local engine on the automatic model; only `activeTarget` points at the API.
    private func computePlan(_ cfg: RemoteConfig) -> ModelPlan {
        var p = HardwareProfiler.select(hardware: hardware, config: cfg)
        autoModelBox.set(p.model)
        AppCoordinator.applyOverride(&p, overrideBox.get(), providers)
        return p
    }

    private static func applyOverride(_ p: inout ModelPlan, _ override: String?, _ providers: ProviderStore) {
        guard let o = override, ProcessInfo.processInfo.environment["LOCALLLM_FORCE_MODEL"] == nil else { return }
        if providers.split(o) != nil {
            p.adjustments.append("Modelo activo remoto: \(o) (el motor local queda en \(p.model))")
        } else {
            p.adjustments.append("Modelo elegido manualmente: \(o) (automático sería \(p.model))")
            p.model = o
        }
    }

    /// What "default", "local" and the aliases resolve to: the local plan model or a remote API model.
    var activeTarget: RouteTarget {
        if let o = overrideBox.get(), ProcessInfo.processInfo.environment["LOCALLLM_FORCE_MODEL"] == nil,
           let (prov, model) = providers.split(o) {
            return .remote(provider: prov, model: model)
        }
        return .local(plan.model)
    }

    private init() {
        hardware = HardwareProfiler.detect()
        var p = HardwareProfiler.select(hardware: hardware, config: config.current)
        autoModelBox.set(p.model)
        AppCoordinator.applyOverride(&p, overrideBox.get(), providers)
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

    /// Routes a requested model name:
    /// empty / "default" / alias → active model (local or remote) ·
    /// installed Ollama model → that local model · "<provider>/<model>" → that API ·
    /// bare name listed by a provider → that API · anything else → active model.
    func resolveTarget(_ requested: String?) -> RouteTarget {
        let active = activeTarget
        guard let req = requested?.trimmingCharacters(in: .whitespaces), !req.isEmpty else { return active }
        let routing = config.current.routing
        if let target = routing.aliases[req] {
            if target == "$auto" { return active }
            if let (p, m) = providers.split(target) { return .remote(provider: p, model: m) }
            return .local(target)
        }
        let local = plan.model
        if req == local || req + ":latest" == local { return .local(local) }
        if req == active.displayName { return active }
        let installed = ollama.installedModels
        if routing.passthroughInstalledModels, installed[req] != nil || installed[req + ":latest"] != nil { return .local(req) }
        if let (p, m) = providers.split(req) { return .remote(provider: p, model: m) }
        if let p = providers.owner(ofBare: req) { return .remote(provider: p, model: req) }
        return active
    }

    /// Local model name for engine-only paths (falls back to the local plan model).
    func resolveModel(_ requested: String?) -> String {
        if case .local(let m) = resolveTarget(requested) { return m }
        return plan.model
    }

    // MARK: Manual model selection

    /// Sets (or clears with nil) the manual model. Pulls it if needed, then loads it in Metal.
    func setModel(_ model: String?) async -> (ok: Bool, detail: String) {
        let m = model?.trimmingCharacters(in: .whitespaces)
        let value = (m?.isEmpty ?? true) ? nil : m
        let remote = value.flatMap { providers.split($0) } != nil
        if let v = value, v.contains("/"), !remote, providers.all.contains(where: { v.hasPrefix($0.id + "/") }) {
            return (false, "el proveedor de \(v) está desactivado")
        }
        if let v = value, !remote, ollama.installedModels[v] == nil, ollama.installedModels[v + ":latest"] == nil,
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
        let active = activeTarget
        tracker.incident("model-selected", value.map { (remote ? "remoto: " : "manual: ") + $0 } ?? "automático: \(newPlan.model)")
        let admission = self.admission
        Task {
            await ollama.apply(plan: newPlan, config: cfg.ollama, admission: admission, drainTimeout: cfg.gateway.drainTimeoutSeconds)
            // Remote model active: free the unified memory the local weights were using.
            if remote, admission.stats.inFlight == 0 { await ollama.unloadModels(); gateway.contextPolicy.forget() }
        }
        return (true, "modelo activo: \(active.displayName)")
    }

    // MARK: Remote providers

    func providersPayload() -> [String: Any] {
        ["providers": providers.all.map(\.publicDictionary), "active": activeTarget.displayName]
    }

    func upsertProvider(_ body: Data) async -> (ok: Bool, detail: String) {
        guard let obj = JSON.object(body) else { return (false, "JSON inválido") }
        let models: [String]
        if let arr = obj["models"] as? [String] { models = arr }
        else if let str = obj["models"] as? String { models = str.split(whereSeparator: { $0 == "," || $0 == "\n" }).map(String.init) }
        else { models = [] }
        let p = RemoteProvider(id: (obj["id"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                               name: obj["name"] as? String ?? "",
                               baseURL: obj["baseURL"] as? String ?? "",
                               apiKey: obj["apiKey"] as? String,
                               apiKeyEnv: (obj["apiKeyEnv"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               models: models,
                               headers: obj["headers"] as? [String: String],
                               enabled: obj["enabled"] as? Bool)
        do { try providers.upsert(p) } catch { return (false, error.localizedDescription) }
        tracker.incident("provider-saved", p.id.lowercased())
        refreshPlanAfterProviderChange(p.id.lowercased())
        return (true, "proveedor \(p.id.lowercased()) guardado")
    }

    func removeProvider(_ id: String) -> (ok: Bool, detail: String) {
        do {
            guard try providers.remove(id) else { return (false, "no existe \(id)") }
        } catch { return (false, error.localizedDescription) }
        tracker.incident("provider-removed", id)
        refreshPlanAfterProviderChange(id)
        return (true, "proveedor \(id) eliminado")
    }

    /// Asks the provider for its model list (GET <baseURL>/models).
    func discoverModels(_ id: String) async -> (ok: Bool, models: [String], detail: String) {
        guard let p = providers.all.first(where: { $0.id == id }),
              let req = providers.request(p, path: "/models", body: Data(), method: "GET") else { return (false, [], "no existe \(id)") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status < 400, let obj = JSON.object(data) else {
                return (false, [], "HTTP \(status): \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
            }
            let list = (obj["data"] as? [[String: Any]] ?? obj["models"] as? [[String: Any]] ?? [])
                .compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
                .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }   // Gemini prefixes "models/"
                .sorted()
            return (true, list, "\(list.count) modelos")
        } catch { return (false, [], error.localizedDescription) }
    }

    /// A removed/disabled provider may have been the active one: drop the override so the
    /// gateway falls back to the local automatic model, then recompute the plan.
    private func refreshPlanAfterProviderChange(_ id: String) {
        if let o = overrideBox.get(), o.hasPrefix(id + "/"), providers.split(o) == nil {
            overrideBox.set(nil)
            try? FileManager.default.removeItem(at: AppPaths.modelOverride)
            tracker.incident("model-selected", "automático: el proveedor de \(o) ya no está disponible")
        }
        let cfg = config.current
        let old = plan
        let newPlan = computePlan(cfg)
        planBox.set(newPlan)
        if newPlan != old {
            let admission = self.admission
            Task { await ollama.apply(plan: newPlan, config: cfg.ollama, admission: admission, drainTimeout: cfg.gateway.drainTimeoutSeconds) }
        }
    }

    func modelsPayload() -> [String: Any] {
        let installed = ollama.installedModels.sorted { $0.key < $1.key }.map { ["name": $0.key, "sizeBytes": $0.value] as [String: Any] }
        let active = activeTarget
        return [
            "active": active.displayName,
            "activeIsRemote": active.isRemote,
            "localModel": plan.model,
            "remote": providers.enabled.map { p in
                ["provider": p.id, "name": p.name, "hasKey": p.resolvedKey != nil,
                 "models": p.models.map { "\(p.id)/\($0)" }] as [String: Any]
            },
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
            "model": activeTarget.displayName,
            "remote": activeTarget.isRemote,
            "localModel": plan.model,
            "breakerOpen": memory.isBreakerOpen,
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
            "model": activeTarget.displayName,
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
