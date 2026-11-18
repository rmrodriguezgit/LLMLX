import Foundation

// MARK: - Remote LLM providers (any OpenAI-compatible API)

/// A remote inference service: OpenAI, Anthropic (OpenAI-compatible endpoint), Google Gemini,
/// OpenRouter, Groq, Mistral, DeepSeek, Together, LM Studio, another Ollama, etc.
/// Stored only on this Mac (Application Support/LocalLLM/providers.json, mode 0600): API keys
/// never go into the Git-synced profiles.json.
struct RemoteProvider: Codable, Equatable {
    /// Short slug used as model prefix: "openai" → model "openai/gpt-4o-mini".
    var id: String
    var name: String
    /// OpenAI-compatible base URL, ending in the API version (e.g. https://api.openai.com/v1).
    var baseURL: String
    /// Literal key (stored locally) — or `apiKeyEnv`, the name of an environment variable.
    var apiKey: String?
    var apiKeyEnv: String?
    /// Models offered in the menus. Any other model can still be requested as "<id>/<model>".
    var models: [String]
    /// Extra headers sent upstream (e.g. OpenRouter's HTTP-Referer).
    var headers: [String: String]?
    var enabled: Bool?

    var isEnabled: Bool { enabled ?? true }

    var resolvedKey: String? {
        if let k = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return k }
        if let e = apiKeyEnv, let v = ProcessInfo.processInfo.environment[e], !v.isEmpty { return v }
        return nil
    }

    var base: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), let scheme = u.scheme, ["http", "https"].contains(scheme), u.host != nil else { return nil }
        return u
    }

    /// Public view (never exposes the key).
    var publicDictionary: [String: Any] {
        let key = resolvedKey
        return [
            "id": id, "name": name, "baseURL": baseURL, "models": models,
            "enabled": isEnabled,
            "hasKey": key != nil,
            "keyHint": key.map { k in k.count > 8 ? "…" + String(k.suffix(4)) : "…" } ?? NSNull(),
            "apiKeyEnv": apiKeyEnv ?? NSNull(),
            "headers": Array((headers ?? [:]).keys).sorted(),
        ]
    }
}

/// Where a request ends up.
enum RouteTarget: Equatable {
    case local(String)
    case remote(provider: RemoteProvider, model: String)

    /// Name reported to clients / metrics: "qwen3:8b" or "openai/gpt-4o-mini".
    var displayName: String {
        switch self {
        case .local(let m): return m
        case .remote(let p, let m): return "\(p.id)/\(m)"
        }
    }
    var isRemote: Bool { if case .remote = self { return true } else { return false } }
}

struct ProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class ProviderStore {
    private let state: Locked<[RemoteProvider]>

    init() { state = Locked(ProviderStore.load()) }

    var all: [RemoteProvider] { state.get() }
    var enabled: [RemoteProvider] { state.get().filter(\.isEnabled) }

    func provider(_ id: String) -> RemoteProvider? { enabled.first { $0.id == id } }

    /// "openai/gpt-4o" → (openai, "gpt-4o") when "openai" is a configured provider.
    func split(_ name: String) -> (RemoteProvider, String)? {
        guard let slash = name.firstIndex(of: "/") else { return nil }
        let id = String(name[..<slash]), model = String(name[name.index(after: slash)...])
        guard !model.isEmpty, let p = provider(id) else { return nil }
        return (p, model)
    }

    /// A bare model name that exactly one listed provider offers ("gpt-4o-mini").
    func owner(ofBare name: String) -> RemoteProvider? {
        enabled.first { $0.models.contains(name) }
    }

    /// Every "<provider>/<model>" offered in menus.
    var catalog: [String] { enabled.flatMap { p in p.models.map { "\(p.id)/\($0)" } } }

    static let idPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,31}$")

    /// Insert or update. An empty/missing `apiKey` keeps the stored one.
    func upsert(_ incoming: RemoteProvider) throws {
        let id = incoming.id.lowercased()
        guard ProviderStore.idPattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil else {
            throw ProviderError(message: "id de proveedor inválido (a-z, 0-9, - o _; máx. 32)")
        }
        guard incoming.base != nil else { throw ProviderError(message: "baseURL debe ser http(s)://host/…") }
        try state.mutate { list in
            var p = incoming
            p.id = id
            p.models = p.models.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if p.name.trimmingCharacters(in: .whitespaces).isEmpty { p.name = id }
            if let i = list.firstIndex(where: { $0.id == id }) {
                if (p.apiKey ?? "").isEmpty { p.apiKey = list[i].apiKey }
                list[i] = p
            } else {
                list.append(p)
            }
            try ProviderStore.save(list)
        }
    }

    func remove(_ id: String) throws -> Bool {
        try state.mutate { list in
            let before = list.count
            list.removeAll { $0.id == id }
            if list.count != before { try ProviderStore.save(list) }
            return list.count != before
        }
    }

    // MARK: Persistence

    private static func load() -> [RemoteProvider] {
        guard let d = try? Data(contentsOf: AppPaths.providers) else { return [] }
        do { return try JSONDecoder().decode([RemoteProvider].self, from: d) } catch {
            Log.error("providers", "Ignoring \(AppPaths.providers.path): \(error.localizedDescription)")
            return []
        }
    }

    private static func save(_ list: [RemoteProvider]) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = AppPaths.providers
        try e.encode(list).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Upstream request

    /// Builds a POST to `<baseURL><path>` with the provider's credentials.
    func request(_ p: RemoteProvider, path: String, body: Data, method: String = "POST") -> URLRequest? {
        guard let base = p.base, let url = URL(string: base.absoluteString + path) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        if method != "GET" {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
        }
        if let k = p.resolvedKey { r.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        for (k, v) in p.headers ?? [:] { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }
}
