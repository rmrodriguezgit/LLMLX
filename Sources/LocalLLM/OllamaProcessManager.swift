import Foundation
import CryptoKit

enum OllamaStatus: Equatable {
    case stopped
    case starting
    case pulling(model: String, progress: Double)
    case loading(model: String)
    case ready(model: String)
    case restarting(reason: String)
    case failed(String)

    var label: String {
        switch self {
        case .stopped: return "Detenido"
        case .starting: return "Iniciando Ollama…"
        case .pulling(let m, let p): return String(format: "Descargando %@ %.0f%%", m, p * 100)
        case .loading(let m): return "Cargando \(m) en Metal…"
        case .ready(let m): return "Listo • \(m)"
        case .restarting(let r): return "Reiniciando: \(r)"
        case .failed(let e): return "Error: \(e)"
        }
    }
}

struct LoadedModel: Codable, Equatable {
    var name: String
    var sizeBytes: UInt64       // total resident (weights + KV cache + compute buffers)
    var sizeVRAMBytes: UInt64
    var weightsBytes: UInt64    // model file size from /api/tags
    var kvCacheBytes: UInt64 { sizeBytes > weightsBytes ? sizeBytes - weightsBytes : 0 }

    enum CodingKeys: String, CodingKey { case name, sizeBytes, sizeVRAMBytes, weightsBytes, contextLength, expiresAt, kvCacheBytes }
    init(name: String, sizeBytes: UInt64, sizeVRAMBytes: UInt64, weightsBytes: UInt64, contextLength: Int?, expiresAt: String?) {
        self.name = name; self.sizeBytes = sizeBytes; self.sizeVRAMBytes = sizeVRAMBytes
        self.weightsBytes = weightsBytes; self.contextLength = contextLength; self.expiresAt = expiresAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        sizeBytes = try c.decode(UInt64.self, forKey: .sizeBytes)
        sizeVRAMBytes = try c.decode(UInt64.self, forKey: .sizeVRAMBytes)
        weightsBytes = try c.decode(UInt64.self, forKey: .weightsBytes)
        contextLength = try c.decodeIfPresent(Int.self, forKey: .contextLength)
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(sizeBytes, forKey: .sizeBytes)
        try c.encode(sizeVRAMBytes, forKey: .sizeVRAMBytes); try c.encode(weightsBytes, forKey: .weightsBytes)
        try c.encodeIfPresent(contextLength, forKey: .contextLength); try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encode(kvCacheBytes, forKey: .kvCacheBytes)
    }
    var contextLength: Int?
    var expiresAt: String?
}

/// Supervises an isolated `ollama serve` child process configured from the ModelPlan.
final class OllamaProcessManager {
    private struct PidFile: Codable { var pid: Int32; var port: Int; var configHash: String; var binary: String }

    private let stateQueue = DispatchQueue(label: "localllm.ollama")
    private var process: Process?
    private var adoptedPid: Int32?
    private var stopping = false
    private var detached = false
    private var restartBackoff: TimeInterval = 1
    private var currentHash = ""
    private var plan: ModelPlan
    private var config: OllamaConfig
    private var supervisorTimer: DispatchSourceTimer?

    private let statusBox = Locked<OllamaStatus>(.stopped)
    private let loadedBox = Locked<[LoadedModel]>([])
    private let installedBox = Locked<[String: UInt64]>([:])
    private let session: URLSession

    var onStatusChange: ((OllamaStatus) -> Void)?

    init(plan: ModelPlan, config: OllamaConfig) {
        self.plan = plan
        self.config = config
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3600
        c.timeoutIntervalForResource = 24 * 3600
        c.httpMaximumConnectionsPerHost = 64
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        session = URLSession(configuration: c)
    }

    var status: OllamaStatus { statusBox.get() }
    var loadedModels: [LoadedModel] { loadedBox.get() }
    var installedModels: [String: UInt64] { installedBox.get() }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(config.port)")! }
    var activeModel: String { plan.model }
    var pid: Int32? { stateQueue.sync { process?.processIdentifier ?? adoptedPid } }

    private func setStatus(_ s: OllamaStatus) {
        statusBox.set(s)
        onStatusChange?(s)
    }

    // MARK: Environment derived from the hardware profile

    static func environment(plan: ModelPlan, config: OllamaConfig) -> [String: String] {
        var env: [String: String] = [
            "OLLAMA_HOST": "127.0.0.1:\(config.port)",
            "OLLAMA_NUM_PARALLEL": String(plan.numParallel),
            "OLLAMA_MAX_LOADED_MODELS": String(config.maxLoadedModels),
            "OLLAMA_KV_CACHE_TYPE": plan.kvCacheType,
            "OLLAMA_FLASH_ATTENTION": plan.flashAttention ? "1" : "0",
            "OLLAMA_CONTEXT_LENGTH": String(plan.numCtx),
            "OLLAMA_KEEP_ALIVE": config.keepAlive,
            "OLLAMA_MAX_QUEUE": String(config.maxQueue),
            "OLLAMA_NOPRUNE": "1"
        ]
        if let dir = config.modelsDir, !dir.isEmpty {
            env["OLLAMA_MODELS"] = (dir as NSString).expandingTildeInPath
        }
        for (k, v) in config.extraEnv { env[k] = v }
        return env
    }

    private static func hash(_ env: [String: String], binary: String) -> String {
        let s = env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";") + "|" + binary
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    static func locateBinary() -> String? {
        var candidates: [String] = []
        if let e = ProcessInfo.processInfo.environment["LOCALLLM_OLLAMA_BIN"], !e.isEmpty { candidates.append(e) }
        if let r = AppEnvironment.resourcesURL {
            candidates.append(r.appendingPathComponent("ollama/ollama").path)
            candidates.append(r.appendingPathComponent("ollama").path)
        }
        candidates += ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
        let fm = FileManager.default
        return candidates.first { path in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue && fm.isExecutableFile(atPath: path)
        }
    }

    // MARK: Lifecycle

    func start() async {
        setStatus(.starting)
        guard let binary = OllamaProcessManager.locateBinary() else {
            setStatus(.failed("binario de Ollama no encontrado"))
            Log.error("ollama", "No ollama binary found (bundle Resources/ollama, Homebrew, Ollama.app)")
            return
        }
        let env = OllamaProcessManager.environment(plan: plan, config: config)
        let hash = OllamaProcessManager.hash(env, binary: binary)
        currentHash = hash

        if await adoptExisting(hash: hash) {
            Log.info("ollama", "Adopted running Ollama (pid \(adoptedPid ?? -1)) on port \(config.port)")
        } else {
            await killStaleFromPidFile()
            launch(binary: binary, env: env, hash: hash)
            guard await waitHealthy(timeout: 30) else {
                setStatus(.failed("Ollama no respondió en el puerto \(config.port)"))
                return
            }
        }
        startSupervisor()
        await prepareModel()
    }

    private func adoptExisting(hash: String) async -> Bool {
        guard let data = try? Data(contentsOf: AppPaths.ollamaPidFile),
              let pf = try? JSONDecoder().decode(PidFile.self, from: data),
              pf.port == config.port, pf.configHash == hash, kill(pf.pid, 0) == 0,
              await isHealthy() else { return false }
        stateQueue.sync { adoptedPid = pf.pid; process = nil }
        return true
    }

    private func killStaleFromPidFile() async {
        guard let data = try? Data(contentsOf: AppPaths.ollamaPidFile),
              let pf = try? JSONDecoder().decode(PidFile.self, from: data), kill(pf.pid, 0) == 0 else { return }
        Log.info("ollama", "Stopping stale Ollama pid \(pf.pid) (config changed)")
        kill(pf.pid, SIGTERM)
        for _ in 0..<50 where kill(pf.pid, 0) == 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
        if kill(pf.pid, 0) == 0 { kill(pf.pid, SIGKILL) }
    }

    private func launch(binary: String, env: [String: String], hash: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["serve"]
        var full = ProcessInfo.processInfo.environment
        for k in full.keys where k.hasPrefix("OLLAMA_") { full.removeValue(forKey: k) }
        for (k, v) in env { full[k] = v }
        p.environment = full
        p.qualityOfService = .userInteractive
        let logURL = AppPaths.logs.appendingPathComponent("ollama.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            p.standardOutput = h
            p.standardError = h
        }
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in self?.handleExit(proc) }
        do {
            try p.run()
            stateQueue.sync { process = p; adoptedPid = nil }
            let pf = PidFile(pid: p.processIdentifier, port: config.port, configHash: hash, binary: binary)
            try? JSONEncoder().encode(pf).write(to: AppPaths.ollamaPidFile, options: .atomic)
            Log.info("ollama", "Launched \(binary) serve pid=\(p.processIdentifier) env=\(env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        } catch {
            setStatus(.failed("no se pudo lanzar Ollama: \(error.localizedDescription)"))
        }
    }

    private func handleExit(_ proc: Process) {
        let (shouldRestart, delay): (Bool, TimeInterval) = stateQueue.sync {
            guard process === proc else { return (false, 0) }
            process = nil
            if stopping || detached { return (false, 0) }
            let d = restartBackoff
            restartBackoff = min(restartBackoff * 2, 30)
            return (true, d)
        }
        guard shouldRestart else { return }
        Log.error("ollama", "Ollama exited unexpectedly (status \(proc.terminationStatus)); restarting in \(delay)s")
        setStatus(.restarting(reason: "Ollama terminó (código \(proc.terminationStatus))"))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            Task { await self.start() }
        }
    }

    /// Supervision for adopted (non-child) processes + refresh of /api/ps and /api/tags.
    private func startSupervisor() {
        supervisorTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.refreshLoaded()
                let adopted: Int32? = self.stateQueue.sync { self.adoptedPid }
                if let pid = adopted, kill(pid, 0) != 0, !self.stateQueue.sync(execute: { self.stopping || self.detached }) {
                    Log.error("ollama", "Adopted Ollama pid \(pid) disappeared; relaunching")
                    self.stateQueue.sync { self.adoptedPid = nil }
                    await self.start()
                }
            }
        }
        t.resume()
        supervisorTimer = t
    }

    /// Stops Ollama. With `detach: true` (blue/green hand-off) the process keeps running so the
    /// new gateway instance adopts it without unloading the model.
    func stop(detach: Bool) async {
        supervisorTimer?.cancel()
        let (p, adopted): (Process?, Int32?) = stateQueue.sync {
            if detach { detached = true } else { stopping = true }
            return (process, adoptedPid)
        }
        guard !detach else { Log.info("ollama", "Detaching from Ollama for hand-off"); return }
        if let p, p.isRunning {
            p.terminate()
            for _ in 0..<50 where p.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        } else if let pid = adopted, kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: AppPaths.ollamaPidFile)
        setStatus(.stopped)
    }

    /// Applies a new plan. Pulls the new model first (while the old one keeps serving), then
    /// restarts the engine only if its environment actually changed.
    func apply(plan newPlan: ModelPlan, config newConfig: OllamaConfig, admission: AdmissionController, drainTimeout: TimeInterval) async {
        let oldEnv = OllamaProcessManager.environment(plan: plan, config: config)
        let newEnv = OllamaProcessManager.environment(plan: newPlan, config: newConfig)
        let modelChanged = newPlan.model != plan.model
        let installed = installedBox.get()
        let isInstalled = installed[newPlan.model] != nil || installed[newPlan.model + ":latest"] != nil
        if modelChanged && newConfig.autoPull && !isInstalled { _ = await pull(newPlan.model) }
        if oldEnv == newEnv {
            plan = newPlan; config = newConfig
            if modelChanged { await prepareModel() }
            return
        }
        Log.info("ollama", "Engine environment changed; rolling restart")
        setStatus(.restarting(reason: "nuevo perfil de hardware"))
        admission.pause()                                    // new requests queue, none fail
        await admission.waitForIdle(timeout: drainTimeout)   // in-flight generations finish
        await stop(detach: false)
        stateQueue.sync { stopping = false; detached = false; restartBackoff = 1 }
        plan = newPlan; config = newConfig
        await start()
        admission.resume()
    }

    // MARK: Model management

    private func prepareModel() async {
        await refreshInstalled()
        var model = plan.model
        if installedBox.get()[model] == nil && installedBox.get()[model + ":latest"] == nil {
            if config.autoPull {
                if !(await pull(model)) {
                    if let fb = plan.fallbackModels.first(where: { installedBox.get()[$0] != nil }) {
                        Log.warn("ollama", "Pull of \(model) failed; using installed fallback \(fb)")
                        model = fb
                    } else if let fb = plan.fallbackModels.first, await pull(fb) {
                        model = fb
                    } else {
                        setStatus(.failed("no se pudo descargar \(plan.model)"))
                        return
                    }
                    plan.model = model
                }
            } else {
                setStatus(.failed("modelo \(model) no instalado (autoPull desactivado)"))
                return
            }
        }
        if config.warmup {
            setStatus(.loading(model: model))
            _ = await post("/api/generate", ["model": model, "prompt": "", "keep_alive": config.keepAlive,
                                              "options": ["num_ctx": plan.numCtx, "num_gpu": plan.numGPU]])
        }
        await refreshLoaded()
        setStatus(.ready(model: model))
    }

    func pull(_ model: String) async -> Bool {
        setStatus(.pulling(model: model, progress: 0))
        var req = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
            var lastError: String?
            for try await line in bytes.lines {
                guard let obj = JSON.object(Data(line.utf8)) else { continue }
                if let e = obj["error"] as? String { lastError = e }
                if let total = JSON.double(obj["total"]), total > 0, let done = JSON.double(obj["completed"]) {
                    setStatus(.pulling(model: model, progress: done / total))
                }
                if obj["status"] as? String == "success" {
                    Log.info("ollama", "Pulled \(model)")
                    await refreshInstalled()
                    return true
                }
            }
            Log.error("ollama", "Pull \(model) ended without success: \(lastError ?? "unknown")")
        } catch {
            Log.error("ollama", "Pull \(model) failed: \(error.localizedDescription)")
        }
        return false
    }

    /// Frees the model's weights and KV cache (keep_alive=0). Used by the memory guard.
    func unloadModels() async {
        for m in loadedBox.get() {
            Log.warn("ollama", "Memory guard: unloading \(m.name) to release KV cache/weights")
            _ = await post("/api/generate", ["model": m.name, "keep_alive": 0])
        }
        await refreshLoaded()
    }

    func refreshInstalled() async {
        guard let obj = await get("/api/tags"), let models = obj["models"] as? [[String: Any]] else { return }
        var map: [String: UInt64] = [:]
        for m in models {
            if let name = m["name"] as? String { map[name] = UInt64(JSON.int(m["size"]) ?? 0) }
        }
        installedBox.set(map)
    }

    func refreshLoaded() async {
        guard let obj = await get("/api/ps"), let models = obj["models"] as? [[String: Any]] else { return }
        let installed = installedBox.get()
        loadedBox.set(models.compactMap { m in
            guard let name = m["name"] as? String else { return nil }
            return LoadedModel(name: name,
                               sizeBytes: UInt64(JSON.int(m["size"]) ?? 0),
                               sizeVRAMBytes: UInt64(JSON.int(m["size_vram"]) ?? 0),
                               weightsBytes: installed[name] ?? 0,
                               contextLength: JSON.int(m["context_length"]),
                               expiresAt: m["expires_at"] as? String)
        })
    }

    func isHealthy() async -> Bool { await get("/api/version") != nil }

    private func waitHealthy(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await isHealthy() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    private func get(_ path: String) async -> [String: Any]? {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.timeoutInterval = 3
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return JSON.object(data)
    }

    private func post(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 600
        guard let (data, _) = try? await session.data(for: req) else { return nil }
        return JSON.object(data)
    }
}
