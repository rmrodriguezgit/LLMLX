import Foundation

// MARK: - Remote configuration schema (config/profiles.json in the Git repo)

struct RemoteConfig: Codable, Equatable {
    var schemaVersion: Int
    var gateway: GatewayConfig
    var ollama: OllamaConfig
    var memoryGuard: MemoryGuardConfig
    var routing: RoutingConfig
    var updater: UpdaterConfig
    var profiles: [HardwareProfileRule]
}

struct GatewayConfig: Codable, Equatable {
    var host: String
    var port: Int
    var maxQueueDepth: Int
    var queueTimeoutSeconds: Double
    var drainTimeoutSeconds: Double
    var maxRequestBodyMB: Int
    /// Browser origins allowed to call the gateway. Requests without an Origin header
    /// (curl, SDKs, IDEs, agents) are always allowed. Blocks drive-by calls from web pages.
    var allowedOrigins: [String]
}

struct OllamaConfig: Codable, Equatable {
    var port: Int
    var keepAlive: String
    var maxLoadedModels: Int
    var maxQueue: Int
    var modelsDir: String?
    var autoPull: Bool
    var warmup: Bool
    var extraEnv: [String: String]
}

struct MemoryGuardConfig: Codable, Equatable {
    var pollIntervalMs: Int
    var hysteresisGB: Double
    var recoverySeconds: Double
    var retryAfterSeconds: Int
    var purgeIdleModelOnPressure: Bool
}

struct RoutingConfig: Codable, Equatable {
    /// "$auto" resolves to the model selected by the HardwareProfiler.
    var aliases: [String: String]
    var passthroughInstalledModels: Bool
    /// Client app name (X-Client-App / User-Agent product) -> "high" | "normal" | "low".
    var clientPriorities: [String: String]
}

struct UpdaterConfig: Codable, Equatable {
    var enabled: Bool
    var remote: String
    var branch: String
    var intervalMinutes: Double
    var autoRebuild: Bool
    var healthCheckTimeoutSeconds: Double
    var buildTimeoutMinutes: Double
}

struct HardwareProfileRule: Codable, Equatable {
    var id: String
    var description: String
    var minMemoryGB: Double
    var maxMemoryGB: Double
    var model: String
    var fallbackModels: [String]
    var quantization: String
    var numCtx: Int
    /// Largest window a client may request (num_ctx). nil = numCtx × 2.
    var maxCtx: Int?
    var minCtx: Int
    var numParallel: Int
    var kvCacheType: String
    var flashAttention: Bool
    var numGPU: Int
    var metalBudgetGB: Double
    var minFreeGB: Double
    var estimatedWeightsGB: Double
    var kvBytesPerTokenF16: Int
    var computeOverheadGB: Double
}

enum ConfigError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let m): return "Invalid profiles.json: \(m)" }
    }
}

// MARK: - Store with hot-reload

final class ConfigStore {
    private let state: Locked<(config: RemoteConfig, source: String)>

    var current: RemoteConfig { state.get().config }
    var source: String { state.get().source }

    init() {
        let (cfg, src) = ConfigStore.loadBest()
        state = Locked((cfg, src))
        Log.info("config", "Loaded configuration from \(src)")
    }

    /// Search order: Git-synced repo -> app bundle Resources -> embedded default.
    static var candidateURLs: [URL] {
        var urls = [AppPaths.repo.appendingPathComponent("config/profiles.json")]
        if let r = AppEnvironment.resourcesURL { urls.append(r.appendingPathComponent("profiles.json")) }
        if let p = ProcessInfo.processInfo.environment["LOCALLLM_CONFIG"], !p.isEmpty {
            urls.insert(URL(fileURLWithPath: p), at: 0)
        }
        return urls
    }

    static func loadBest() -> (RemoteConfig, String) {
        for url in candidateURLs where FileManager.default.fileExists(atPath: url.path) {
            do { return (try parse(Data(contentsOf: url)), url.path) } catch {
                Log.error("config", "Ignoring \(url.path): \(error.localizedDescription)")
            }
        }
        // swiftlint:disable:next force_try
        return (try! parse(Data(EmbeddedConfig.json.utf8)), "embedded-default")
    }

    static func parse(_ data: Data) throws -> RemoteConfig {
        let cfg: RemoteConfig
        do { cfg = try JSONDecoder().decode(RemoteConfig.self, from: data) } catch {
            throw ConfigError.invalid(String(describing: error))
        }
        try validate(cfg)
        return cfg
    }

    static func validate(_ c: RemoteConfig) throws {
        guard c.schemaVersion == 1 else { throw ConfigError.invalid("unsupported schemaVersion \(c.schemaVersion)") }
        guard !c.profiles.isEmpty else { throw ConfigError.invalid("profiles is empty") }
        guard (1...65535).contains(c.gateway.port), (1...65535).contains(c.ollama.port), c.gateway.port != c.ollama.port else {
            throw ConfigError.invalid("invalid ports")
        }
        for p in c.profiles {
            guard p.numParallel >= 1, p.numCtx >= 512, p.minCtx >= 512, p.minCtx <= p.numCtx else {
                throw ConfigError.invalid("profile \(p.id): numParallel/numCtx out of range")
            }
            if let maxCtx = p.maxCtx, maxCtx < p.numCtx {
                throw ConfigError.invalid("profile \(p.id): maxCtx < numCtx")
            }
            guard p.maxMemoryGB > p.minMemoryGB, p.metalBudgetGB > 0, !p.model.isEmpty else {
                throw ConfigError.invalid("profile \(p.id): memory range / budget / model invalid")
            }
            guard ["f16", "q8_0", "q4_0"].contains(p.kvCacheType) else {
                throw ConfigError.invalid("profile \(p.id): kvCacheType must be f16, q8_0 or q4_0")
            }
        }
        guard c.updater.intervalMinutes >= 1 else { throw ConfigError.invalid("updater.intervalMinutes must be >= 1") }
    }

    /// Re-reads the configuration from disk. On failure the previous configuration stays active.
    @discardableResult
    func reload() throws -> (old: RemoteConfig, new: RemoteConfig) {
        // Same precedence as startup: LOCALLLM_CONFIG > Git repo > bundle.
        guard let target = ConfigStore.candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ConfigError.invalid("no profiles.json found")
        }
        let new = try ConfigStore.parse(Data(contentsOf: target))
        let old = state.mutate { s -> RemoteConfig in
            let o = s.config
            s = (new, target.path)
            return o
        }
        Log.info("config", "Hot-reloaded configuration from \(target.path)")
        return (old, new)
    }
}
