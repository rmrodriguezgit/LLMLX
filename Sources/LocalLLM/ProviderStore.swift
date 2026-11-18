import Foundation
import Security

// MARK: - Schema of ~/Library/Application Support/LocalLLM/providers.json
//
// This file is local to each Mac (never in Git: it holds API keys) and is re-read whenever it
// changes on disk, so providers can be added or edited from the dashboard or with a text editor
// without restarting or rebuilding the app.

enum ProviderKind: String, Codable {
    /// The embedded Ollama engine on this Mac (the built-in "local" provider).
    case ollama
    /// Any OpenAI-compatible API: ChatGPT/OpenAI, LocalIA on the Ubuntu server, LM Studio, vLLM, OpenRouter…
    case openai
    /// Claude through the native Anthropic Messages API.
    case anthropic
}

struct ProviderConfig: Codable, Equatable {
    var id: String
    var type: ProviderKind
    var name: String
    var enabled: Bool
    var baseUrl: String?
    var apiKey: String?
    var defaultModel: String?
    /// Extra model ids offered in pickers and `/v1/models` as `<id>/<model>`.
    var models: [String]?
    /// Extra HTTP headers sent upstream (e.g. OpenRouter's HTTP-Referer).
    var headers: [String: String]?
    /// PEM/DER root CA trusted for this provider only (LocalIA's self-signed LAN CA).
    var caCertPath: String?
    /// Skips TLS verification. Only for tests on a trusted network.
    var allowInsecureTLS: Bool?
    var timeoutSeconds: Double?
    /// Anthropic requires max_tokens; used when the client does not send one.
    var maxTokens: Int?
    /// Anthropic server-side refusal fallbacks (on by default for the models that support them).
    var refusalFallbacks: Bool?

    init(id: String, type: ProviderKind, name: String, enabled: Bool, baseUrl: String? = nil, apiKey: String? = nil,
         defaultModel: String? = nil, models: [String]? = nil) {
        self.id = id; self.type = type; self.name = name; self.enabled = enabled
        self.baseUrl = baseUrl; self.apiKey = apiKey; self.defaultModel = defaultModel; self.models = models
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(ProviderKind.self, forKey: .type)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        models = try c.decodeIfPresent([String].self, forKey: .models)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
        caCertPath = try c.decodeIfPresent(String.self, forKey: .caCertPath)
        allowInsecureTLS = try c.decodeIfPresent(Bool.self, forKey: .allowInsecureTLS)
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        refusalFallbacks = try c.decodeIfPresent(Bool.self, forKey: .refusalFallbacks)
    }

    var isLocal: Bool { type == .ollama }
    var hasKey: Bool { !(apiKey ?? "").isEmpty }

    /// Every model offered for this provider (default first, no duplicates).
    var offeredModels: [String] {
        var out: [String] = []
        for m in [defaultModel].compactMap({ $0 }) + (models ?? []) where !m.isEmpty && !out.contains(m) { out.append(m) }
        return out
    }

    /// Normalised base URL: OpenAI-compatible ends with /v1 (as the user typed it); Anthropic without /v1.
    var resolvedBaseURL: URL? {
        var s = (baseUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty {
            switch type {
            case .anthropic: s = "https://api.anthropic.com"
            case .openai: s = "https://api.openai.com/v1"
            case .ollama: return nil
            }
        }
        while s.hasSuffix("/") { s.removeLast() }
        if type == .anthropic, s.hasSuffix("/v1") { s.removeLast(3) }
        return URL(string: s)
    }
}

struct ProvidersFile: Codable, Equatable {
    var version: Int
    /// Provider that receives `"model": "default"` (and the routing aliases). "local" = Ollama on this Mac.
    var defaultProvider: String
    var providers: [ProviderConfig]

    static let seed = ProvidersFile(version: 1, defaultProvider: "local", providers: [
        ProviderConfig(id: "local", type: .ollama, name: "Ollama en este Mac", enabled: true),
        ProviderConfig(id: "localia", type: .openai, name: "LocalIA (servidor Ubuntu)", enabled: false,
                       baseUrl: "https://192.168.4.59:8443/v1", defaultModel: ""),
        ProviderConfig(id: "openai", type: .openai, name: "ChatGPT (OpenAI)", enabled: false,
                       baseUrl: "https://api.openai.com/v1", defaultModel: "gpt-5"),
        ProviderConfig(id: "claude", type: .anthropic, name: "Claude (Anthropic)", enabled: false,
                       baseUrl: "https://api.anthropic.com", defaultModel: "claude-opus-5-5",
                       models: ["claude-sonnet-5-5", "claude-haiku-5-5"]),
    ])
}

enum ProviderError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let m) = self { return m }; return nil }
}

// MARK: - Route decision

enum ModelRoute {
    case local(model: String)
    case remote(provider: ProviderConfig, model: String)

    /// Name stored in telemetry and returned in X-LocalLLM-Model.
    var label: String {
        switch self {
        case .local(let m): return m
        case .remote(let p, let m): return "\(p.id)/\(m)"
        }
    }
}

// MARK: - Store

final class ProviderStore: @unchecked Sendable {
    let url: URL
    private struct State { var file: ProvidersFile; var mtime: Date?; var error: String? }
    private let state: Locked<State>
    private let sessions = Locked<[String: (key: String, session: URLSession)]>([:])

    init(url: URL = AppPaths.providers) {
        self.url = url
        state = Locked(State(file: .seed, mtime: nil, error: nil))
        if !FileManager.default.fileExists(atPath: url.path) {
            try? write(.seed)
            Log.info("providers", "Created \(url.path) with built-in presets (disabled)")
        }
        _ = current
    }

    /// Current configuration; re-reads the file when its modification date changes.
    var current: ProvidersFile {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return state.mutate { s in
            guard mtime != s.mtime else { return s.file }
            s.mtime = mtime
            guard let data = try? Data(contentsOf: url) else { return s.file }
            do {
                let f = try JSONDecoder().decode(ProvidersFile.self, from: data)
                try ProviderStore.validate(f)
                s.file = ProviderStore.withLocal(f)
                s.error = nil
                Log.info("providers", "Loaded \(f.providers.count) provider(s); default=\(f.defaultProvider)")
            } catch {
                s.error = "providers.json inválido: \(error.localizedDescription) (se mantiene la última configuración válida)"
                Log.warn("providers", s.error!)
            }
            return s.file
        }
    }

    var loadError: String? { _ = current; return state.get().error }

    func provider(_ id: String) -> ProviderConfig? { current.providers.first { $0.id == id } }

    // MARK: Routing

    /// `claude/claude-opus-5-5`, `openai` (its default model), a model listed by an enabled provider,
    /// or "default"/aliases when the default provider is remote. Everything else stays on Ollama.
    func route(_ requested: String?, aliases: [String: String], local: (String?) -> String) -> ModelRoute {
        let f = current
        let remote = f.providers.filter { $0.enabled && !$0.isLocal }
        let req = requested?.trimmingCharacters(in: .whitespaces) ?? ""

        if let slash = req.firstIndex(of: "/") {
            let pid = String(req[..<slash]), rest = String(req[req.index(after: slash)...])
            if pid == "local" { return .local(model: local(rest.isEmpty ? nil : rest)) }
            if let p = remote.first(where: { $0.id == pid }) {
                return .remote(provider: p, model: rest.isEmpty ? (p.defaultModel ?? "") : rest)
            }
        }
        if req == "local" { return .local(model: local(nil)) }
        if let p = remote.first(where: { $0.id == req }) { return .remote(provider: p, model: p.defaultModel ?? "") }
        if !req.isEmpty, let p = remote.first(where: { $0.offeredModels.contains(req) }) { return .remote(provider: p, model: req) }

        let isDefault = req.isEmpty || aliases[req] == "$auto"
        if isDefault, f.defaultProvider != "local", let p = remote.first(where: { $0.id == f.defaultProvider }) {
            return .remote(provider: p, model: p.defaultModel ?? "")
        }
        return .local(model: local(requested))
    }

    // MARK: Editing (dashboard / API)

    /// Replaces the configuration. A provider sent without `apiKey` keeps its stored key, unless its
    /// type or base URL changed (so a page cannot redirect a saved key to another host).
    func replace(with incoming: [String: Any]) throws -> ProvidersFile {
        let old = current
        let rawProviders = incoming["providers"] as? [[String: Any]] ?? []
        var providers: [ProviderConfig] = []
        for raw in rawProviders {
            var p = try ProviderStore.decodeProvider(raw)
            ProviderStore.inheritKey(&p, raw: raw, old: old)
            providers.append(p)
        }
        let file = ProvidersFile(version: 1,
                                 defaultProvider: (incoming["defaultProvider"] as? String) ?? old.defaultProvider,
                                 providers: providers)
        try ProviderStore.validate(file)
        let final = ProviderStore.withLocal(file)
        try write(final)
        _ = current
        sessions.set([:])
        return final
    }

    /// Makes `id` the provider that answers "default" and the aliases; for an API, `model` also
    /// becomes its default model. Used by the menu bar picker (the dashboard uses `replace`).
    @discardableResult
    func select(provider id: String, model: String? = nil) throws -> ProvidersFile {
        var f = current
        guard let i = f.providers.firstIndex(where: { $0.id == id }) else { throw ProviderError.invalid("proveedor \(id) no encontrado") }
        guard f.providers[i].enabled else { throw ProviderError.invalid("\(f.providers[i].name) está desactivado; actívalo en Admin") }
        if let m = model, !m.isEmpty, !f.providers[i].isLocal { f.providers[i].defaultModel = m }
        f.defaultProvider = id
        try ProviderStore.validate(f)
        try write(f)
        _ = current
        return f
    }

    /// Builds the provider to test from a draft (unsaved form) or a stored id.
    func draft(from body: [String: Any]) throws -> ProviderConfig {
        if let raw = body["provider"] as? [String: Any] {
            var p = try ProviderStore.decodeProvider(raw)
            ProviderStore.inheritKey(&p, raw: raw, old: current)
            return p
        }
        guard let id = body["id"] as? String, let p = provider(id) else { throw ProviderError.invalid("proveedor no encontrado") }
        return p
    }

    private static func decodeProvider(_ raw: [String: Any]) throws -> ProviderConfig {
        var clean = raw
        clean.removeValue(forKey: "hasApiKey"); clean.removeValue(forKey: "apiKeyHint"); clean.removeValue(forKey: "clearApiKey")
        if (clean["apiKey"] as? String)?.isEmpty == true { clean.removeValue(forKey: "apiKey") }
        let data = try JSONSerialization.data(withJSONObject: clean)
        do { return try JSONDecoder().decode(ProviderConfig.self, from: data) } catch {
            throw ProviderError.invalid("proveedor \(raw["id"] ?? "?"): \(error.localizedDescription)")
        }
    }

    private static func inheritKey(_ p: inout ProviderConfig, raw: [String: Any], old: ProvidersFile) {
        guard p.apiKey == nil, raw["clearApiKey"] as? Bool != true,
              let prev = old.providers.first(where: { $0.id == p.id }),
              prev.type == p.type, prev.resolvedBaseURL == p.resolvedBaseURL else { return }
        p.apiKey = prev.apiKey
    }

    private static func withLocal(_ f: ProvidersFile) -> ProvidersFile {
        var f = f
        if !f.providers.contains(where: { $0.id == "local" }) {
            f.providers.insert(ProviderConfig(id: "local", type: .ollama, name: "Ollama en este Mac", enabled: true), at: 0)
        }
        if let i = f.providers.firstIndex(where: { $0.id == "local" }) { f.providers[i].enabled = true }
        return f
    }

    static func validate(_ f: ProvidersFile) throws {
        var seen = Set<String>()
        let idPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_.-]{0,31}$")
        for p in f.providers {
            guard idPattern.firstMatch(in: p.id, range: NSRange(p.id.startIndex..., in: p.id)) != nil else {
                throw ProviderError.invalid("id \"\(p.id)\" no válido: usa minúsculas, números, '-', '_' o '.' (máx. 32)")
            }
            guard seen.insert(p.id).inserted else { throw ProviderError.invalid("id duplicado: \(p.id)") }
            if p.type == .ollama && p.id != "local" { throw ProviderError.invalid("el tipo ollama está reservado para \"local\"; usa el tipo openai con http://host:11434/v1 para otro servidor Ollama") }
            if p.id == "local" && p.type != .ollama { throw ProviderError.invalid("\"local\" debe ser de tipo ollama") }
            if !p.isLocal {
                guard let u = p.resolvedBaseURL, let scheme = u.scheme, ["http", "https"].contains(scheme), u.host != nil else {
                    throw ProviderError.invalid("\(p.id): baseUrl no válida")
                }
                if p.enabled && (p.defaultModel ?? "").isEmpty && (p.models ?? []).isEmpty {
                    throw ProviderError.invalid("\(p.id): indica un modelo predeterminado")
                }
            }
        }
        if f.defaultProvider != "local" {
            guard let d = f.providers.first(where: { $0.id == f.defaultProvider }) else {
                throw ProviderError.invalid("defaultProvider \"\(f.defaultProvider)\" no existe")
            }
            guard d.enabled else { throw ProviderError.invalid("el proveedor predeterminado \"\(d.id)\" está desactivado") }
        }
    }

    private func write(_ f: ProvidersFile) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(f)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Payload (keys never leave the process)

    func payload() -> [String: Any] {
        let f = current
        let providers: [[String: Any]] = f.providers.map { p in
            var d = (JSON.dictionary(p) as? [String: Any]) ?? [:]
            d.removeValue(forKey: "apiKey")
            d["hasApiKey"] = p.hasKey
            if let k = p.apiKey, k.count > 8 { d["apiKeyHint"] = "…" + k.suffix(4) }
            d["offeredModels"] = p.offeredModels
            return d
        }
        return ["path": url.path, "defaultProvider": f.defaultProvider, "providers": providers,
                "error": state.get().error ?? NSNull()]
    }

    // MARK: HTTP sessions (per provider: custom CA / insecure TLS / timeout)

    func session(for p: ProviderConfig) -> URLSession {
        let key = "\(p.caCertPath ?? "")|\(p.allowInsecureTLS ?? false)|\(p.timeoutSeconds ?? 0)"
        if let cached = sessions.get()[p.id], cached.key == key { return cached.session }
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = p.timeoutSeconds ?? 600
        c.timeoutIntervalForResource = 24 * 3600
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        let delegate = TrustDelegate(anchors: p.caCertPath.map(ProviderStore.loadCertificates) ?? [],
                                     insecure: p.allowInsecureTLS ?? false)
        let s = URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
        sessions.mutate { $0[p.id] = (key, s) }
        return s
    }

    static func loadCertificates(_ path: String) -> [SecCertificate] {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else {
            Log.warn("providers", "CA certificate not readable: \(expanded)")
            return []
        }
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            return text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().compactMap { block in
                let b64 = block.components(separatedBy: "-----END CERTIFICATE-----")[0]
                    .components(separatedBy: .whitespacesAndNewlines).joined()
                return Data(base64Encoded: b64).flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            }
        }
        return SecCertificateCreateWithData(nil, data as CFData).map { [$0] } ?? []
    }
}

/// Trusts an extra root CA (or, if asked, any certificate) for one provider's session.
private final class TrustDelegate: NSObject, URLSessionDelegate {
    let anchors: [SecCertificate]
    let insecure: Bool
    init(anchors: [SecCertificate], insecure: Bool) { self.anchors = anchors; self.insecure = insecure }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        if insecure { completionHandler(.useCredential, URLCredential(trust: trust)); return }
        guard !anchors.isEmpty else { completionHandler(.performDefaultHandling, nil); return }
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)   // system roots stay valid too
        var err: CFError?
        if SecTrustEvaluateWithError(trust, &err) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            Log.warn("providers", "TLS rejected for \(challenge.protectionSpace.host): \(err.map { "\($0)" } ?? "?")")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
