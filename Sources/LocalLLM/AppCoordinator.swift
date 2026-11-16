import Foundation
import AppKit

/// Wires every subsystem together and owns the process lifecycle (start, hot-reload,
/// blue/green hand-off, shutdown).
final class AppCoordinator {
    static let shared = AppCoordinator()

    let config = ConfigStore()
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

    private init() {
        hardware = HardwareProfiler.detect()
        let p = HardwareProfiler.select(hardware: hardware, config: config.current)
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
            Task { await ollama.unloadModels() }
        } else {
            pendingPurge = true   // purge as soon as the in-flight generations finish
        }
    }

    private func idleReached() {
        guard pendingPurge, memory.isBreakerOpen else { pendingPurge = false; return }
        pendingPurge = false
        Task { await ollama.unloadModels() }
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

    // MARK: Hot reload (Level 1)

    func reloadConfig(reason: String) async -> (ok: Bool, detail: String) {
        let old: RemoteConfig, new: RemoteConfig
        do { (old, new) = try config.reload() } catch {
            tracker.incident("config-reload-rejected", "\(reason): \(error.localizedDescription)")
            return (false, error.localizedDescription)
        }
        let oldPlan = plan
        let newPlan = HardwareProfiler.select(hardware: hardware, config: new)
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
    func performBlueGreenRestart(binary: URL, commit: String) async -> Bool {
        guard mode == .app || mode == .headless else { return false }
        let p = Process()
        p.executableURL = binary
        p.arguments = mode == .headless ? ["--headless"] : []
        var env = ProcessInfo.processInfo.environment
        env["LOCALLLM_TAKEOVER"] = "1"
        env["LOCALLLM_PARENT_PID"] = String(getpid())
        env["LOCALLLM_COMMIT"] = commit
        env["LOCALLLM_REDIRECTED"] = "1"
        if let b = AppEnvironment.appBundleURL { env["LOCALLLM_APP_BUNDLE"] = b.path }
        if let r = AppEnvironment.resourcesURL { env["LOCALLLM_RESOURCES"] = r.path }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        let ready: Bool = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            handoffLock.lock(); handoffContinuation = c; handoffLock.unlock()
            do { try p.run() } catch {
                handoffLock.lock(); handoffContinuation = nil; handoffLock.unlock()
                c.resume(returning: false)
                return
            }
            Log.info("handoff", "Started new instance pid \(p.processIdentifier) (\(commit.prefix(8))); waiting for ready signal")
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
            if p.isRunning { p.terminate() }
            tracker.incident("handoff-failed", "new instance \(commit.prefix(8)) did not signal ready")
            return false
        }
        tracker.incident("handoff", "new instance \(commit.prefix(8)) pid \(p.processIdentifier) took over; draining")
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
            "breakerOpen": memory.isBreakerOpen
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

    func metricsPayload(window: String?) -> [String: Any] {
        let since: Date?
        switch window ?? "all" {
        case "1h": since = Date().addingTimeInterval(-3600)
        case "24h": since = Date().addingTimeInterval(-86_400)
        case "7d": since = Date().addingTimeInterval(-7 * 86_400)
        case "session": since = startedAt
        default: since = nil
        }
        var m = tracker.metrics(since: since)
        let a = admission.stats
        m["window"] = window ?? "all"
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
        setenv("LOCALLLM_REDIRECTED", "1", 1)
        setenv("LOCALLLM_COMMIT", commit, 1)
        if let b = AppEnvironment.appBundleURL { setenv("LOCALLLM_APP_BUNDLE", b.path, 1) }
        if let r = AppEnvironment.resourcesURL { setenv("LOCALLLM_RESOURCES", r.path, 1) }
        Log.info("launcher", "Executing auto-updated binary \(path) (\(commit.prefix(8)))")
        var args: [UnsafeMutablePointer<CChar>?] = ([path] + CommandLine.arguments.dropFirst()).map { strdup($0) }
        args.append(nil)
        execv(path, &args)
        Log.error("launcher", "execv failed (\(errno)); continuing with bundled binary")
    }
}
