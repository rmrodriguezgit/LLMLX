import Foundation
import NIOHTTP1

// Remote LLM providers behind the same gateway endpoints.
//
//   client format (what the app sent)        upstream (provider type)
//   /v1/chat/completions, /v1/completions ─┐  openai     → OpenAI-compatible relay (no translation)
//   /api/chat, /api/generate (Ollama)      ─┴► anthropic  → native Messages API (/v1/messages)
//
// Requests are converted to a small canonical form, sent upstream, and the upstream stream is
// re-encoded event by event in the client's own format (OpenAI SSE or Ollama NDJSON), so every
// existing client — including the dashboard chat — works with Claude, ChatGPT or LocalIA.

// MARK: - Canonical request

enum CanonPart {
    case text(String)
    case image(mediaType: String, base64: String)
    case imageURL(String)
}

struct CanonToolCall { var id: String; var name: String; var arguments: String }

struct CanonMessage {
    var role: String              // user | assistant | tool
    var parts: [CanonPart] = []
    var toolCalls: [CanonToolCall] = []
    var toolCallId: String?
    var text: String { parts.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n") }
}

struct CanonRequest {
    var system: [String] = []
    var messages: [CanonMessage] = []
    var maxTokens: Int?
    var temperature: Double?
    var topP: Double?
    var stop: [String]?
    var tools: [[String: Any]]?   // OpenAI function-tool shape
    var toolChoice: Any?
    var think: Bool?
    var effort: String?
    var jsonMode = false
    var stream: Bool

    // MARK: Parsers

    static func fromOpenAI(_ j: [String: Any], kind: EndpointKind, stream: Bool) -> CanonRequest {
        var c = CanonRequest(stream: stream)
        if kind == .openAICompletions {
            let prompt = (j["prompt"] as? String) ?? (j["prompt"] as? [String])?.joined(separator: "\n") ?? ""
            c.messages = [CanonMessage(role: "user", parts: [.text(prompt)])]
            if let s = j["suffix"] as? String, !s.isEmpty { c.system.append("Continúa el texto; debe terminar antes de: \(s)") }
        }
        for m in j["messages"] as? [[String: Any]] ?? [] {
            let role = m["role"] as? String ?? "user"
            let parts = parseOpenAIContent(m["content"])
            if role == "system" || role == "developer" {
                c.system.append(parts.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n"))
                continue
            }
            var msg = CanonMessage(role: role == "tool" ? "tool" : (role == "assistant" ? "assistant" : "user"), parts: parts)
            msg.toolCallId = m["tool_call_id"] as? String
            for tc in m["tool_calls"] as? [[String: Any]] ?? [] {
                let fn = tc["function"] as? [String: Any] ?? [:]
                msg.toolCalls.append(CanonToolCall(id: tc["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))",
                                                   name: fn["name"] as? String ?? "",
                                                   arguments: argumentsString(fn["arguments"])))
            }
            c.messages.append(msg)
        }
        c.maxTokens = JSON.int(j["max_completion_tokens"]) ?? JSON.int(j["max_tokens"])
        c.temperature = JSON.double(j["temperature"])
        c.topP = JSON.double(j["top_p"])
        c.stop = (j["stop"] as? [String]) ?? (j["stop"] as? String).map { [$0] }
        c.tools = j["tools"] as? [[String: Any]]
        c.toolChoice = j["tool_choice"]
        if let e = j["reasoning_effort"] as? String { c.effort = e }
        if let rf = j["response_format"] as? [String: Any], let t = rf["type"] as? String, t != "text" { c.jsonMode = true }
        return c
    }

    static func fromOllama(_ j: [String: Any], kind: EndpointKind, stream: Bool) -> CanonRequest {
        var c = CanonRequest(stream: stream)
        var pendingIds: [String] = []
        if kind == .ollamaGenerate {
            if let s = j["system"] as? String, !s.isEmpty { c.system.append(s) }
            var parts: [CanonPart] = [.text(j["prompt"] as? String ?? "")]
            parts += (j["images"] as? [String] ?? []).map { .image(mediaType: sniffImage($0), base64: $0) }
            c.messages = [CanonMessage(role: "user", parts: parts)]
        }
        for m in j["messages"] as? [[String: Any]] ?? [] {
            let role = m["role"] as? String ?? "user"
            let text = m["content"] as? String ?? ""
            if role == "system" { c.system.append(text); continue }
            var msg = CanonMessage(role: role == "tool" ? "tool" : (role == "assistant" ? "assistant" : "user"))
            if !text.isEmpty { msg.parts.append(.text(text)) }
            msg.parts += (m["images"] as? [String] ?? []).map { .image(mediaType: sniffImage($0), base64: $0) }
            for tc in m["tool_calls"] as? [[String: Any]] ?? [] {
                let fn = tc["function"] as? [String: Any] ?? [:]
                let id = tc["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
                pendingIds.append(id)
                msg.toolCalls.append(CanonToolCall(id: id, name: fn["name"] as? String ?? "", arguments: argumentsString(fn["arguments"])))
            }
            if msg.role == "tool" {
                msg.toolCallId = (m["tool_call_id"] as? String) ?? (pendingIds.isEmpty ? "call_0" : pendingIds.removeFirst())
            }
            c.messages.append(msg)
        }
        let o = j["options"] as? [String: Any] ?? [:]
        if let n = JSON.int(o["num_predict"]), n > 0 { c.maxTokens = n }
        c.temperature = JSON.double(o["temperature"])
        c.topP = JSON.double(o["top_p"])
        c.stop = o["stop"] as? [String]
        c.tools = j["tools"] as? [[String: Any]]
        if let t = j["think"] as? Bool { c.think = t } else if let e = j["think"] as? String { c.think = true; c.effort = e }
        if j["format"] != nil { c.jsonMode = true }
        return c
    }

    private static func parseOpenAIContent(_ any: Any?) -> [CanonPart] {
        if let s = any as? String { return s.isEmpty ? [] : [.text(s)] }
        var out: [CanonPart] = []
        for p in any as? [[String: Any]] ?? [] {
            switch p["type"] as? String {
            case "text", "input_text": if let t = p["text"] as? String { out.append(.text(t)) }
            case "image_url":
                let url = (p["image_url"] as? [String: Any])?["url"] as? String ?? p["image_url"] as? String ?? ""
                if let (mt, b64) = dataURL(url) { out.append(.image(mediaType: mt, base64: b64)) } else if !url.isEmpty { out.append(.imageURL(url)) }
            default: break
            }
        }
        return out
    }

    static func argumentsString(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let o = any, JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o) {
            return String(decoding: d, as: UTF8.self)
        }
        return "{}"
    }

    static func dataURL(_ s: String) -> (String, String)? {
        guard s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") else { return nil }
        let meta = s[s.index(s.startIndex, offsetBy: 5)..<comma]
        guard meta.hasSuffix(";base64") else { return nil }
        return (String(meta.dropLast(7)), String(s[s.index(after: comma)...]))
    }

    static func sniffImage(_ b64: String) -> String {
        if b64.hasPrefix("iVBOR") { return "image/png" }
        if b64.hasPrefix("R0lGOD") { return "image/gif" }
        if b64.hasPrefix("UklGR") { return "image/webp" }
        return "image/jpeg"
    }

    // MARK: Builders

    func openAIBody(model: String, provider: ProviderConfig) -> [String: Any] {
        var msgs: [[String: Any]] = []
        let sys = system.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !sys.isEmpty { msgs.append(["role": "system", "content": sys]) }
        for m in messages {
            var d: [String: Any] = ["role": m.role]
            let onlyText = m.parts.allSatisfy { if case .text = $0 { return true }; return false }
            if onlyText {
                d["content"] = m.text
            } else {
                d["content"] = m.parts.map { p -> [String: Any] in
                    switch p {
                    case .text(let t): return ["type": "text", "text": t]
                    case .image(let mt, let b64): return ["type": "image_url", "image_url": ["url": "data:\(mt);base64,\(b64)"]]
                    case .imageURL(let u): return ["type": "image_url", "image_url": ["url": u]]
                    }
                }
            }
            if !m.toolCalls.isEmpty {
                d["tool_calls"] = m.toolCalls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }
            }
            if m.role == "tool" { d["tool_call_id"] = m.toolCallId ?? "call_0" }
            msgs.append(d)
        }
        var b: [String: Any] = ["model": model, "messages": msgs, "stream": stream]
        if stream { b["stream_options"] = ["include_usage": true] }
        if let n = maxTokens {
            // api.openai.com reasoning models reject max_tokens; other OpenAI-compatible servers expect it.
            b[(provider.resolvedBaseURL?.host ?? "").hasSuffix("openai.com") ? "max_completion_tokens" : "max_tokens"] = n
        }
        if let t = temperature { b["temperature"] = t }
        if let t = topP { b["top_p"] = t }
        if let s = stop, !s.isEmpty { b["stop"] = s }
        if let t = tools, !t.isEmpty { b["tools"] = t }
        if let tc = toolChoice { b["tool_choice"] = tc }
        if let e = effort { b["reasoning_effort"] = e }
        if jsonMode { b["response_format"] = ["type": "json_object"] }
        return b
    }

    /// Claude Messages API body (API version 2026-10-21: no temperature/top_p/top_k; forced tool_choice
    /// is rejected by the newest models, so it degrades to "auto").
    func anthropicBody(model: String, provider: ProviderConfig) -> (body: [String: Any], beta: String?) {
        var out: [[String: Any]] = []
        func append(_ role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if var last = out.last, last["role"] as? String == role, var prev = last["content"] as? [[String: Any]] {
                prev += blocks; last["content"] = prev; out[out.count - 1] = last
            } else {
                out.append(["role": role, "content": blocks])
            }
        }
        for m in messages {
            switch m.role {
            case "tool":
                append("user", [["type": "tool_result", "tool_use_id": m.toolCallId ?? "call_0", "content": m.text]])
            case "assistant":
                var blocks: [[String: Any]] = m.text.isEmpty ? [] : [["type": "text", "text": m.text]]
                for tc in m.toolCalls {
                    let input = (try? JSONSerialization.jsonObject(with: Data(tc.arguments.utf8))) as? [String: Any] ?? [:]
                    blocks.append(["type": "tool_use", "id": tc.id, "name": tc.name, "input": input])
                }
                append("assistant", blocks)
            default:
                append("user", m.parts.compactMap { p -> [String: Any]? in
                    switch p {
                    case .text(let t): return t.isEmpty ? nil : ["type": "text", "text": t]
                    case .image(let mt, let b64): return ["type": "image", "source": ["type": "base64", "media_type": mt, "data": b64]]
                    case .imageURL(let u): return ["type": "image", "source": ["type": "url", "url": u]]
                    }
                })
            }
        }
        // The conversation must start with a user turn.
        if out.first?["role"] as? String == "assistant" { out.insert(["role": "user", "content": [["type": "text", "text": "…"]]], at: 0) }

        var b: [String: Any] = ["model": model, "messages": out,
                                "max_tokens": maxTokens ?? provider.maxTokens ?? (stream ? 64000 : 16000)]
        if stream { b["stream"] = true }
        var sys = system.filter { !$0.isEmpty }
        if jsonMode { sys.append("Responde únicamente con un objeto JSON válido, sin texto adicional ni bloques de código.") }
        if !sys.isEmpty { b["system"] = sys.joined(separator: "\n\n") }
        if let s = stop, !s.isEmpty { b["stop_sequences"] = s }
        if let t = tools, !t.isEmpty {
            b["tools"] = t.compactMap { tool -> [String: Any]? in
                guard let fn = tool["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
                var d: [String: Any] = ["name": name, "input_schema": fn["parameters"] ?? ["type": "object", "properties": [String: Any]()]]
                if let desc = fn["description"] as? String { d["description"] = desc }
                return d
            }
            if let tc = toolChoice as? String, tc == "none" { b["tool_choice"] = ["type": "none"] }
        }
        if think == true { b["thinking"] = ["type": "adaptive", "display": "summarized"] }
        if let e = effort {
            let map = ["minimal": "low", "low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh", "max": "max"]
            if let v = map[e] { b["output_config"] = ["effort": v] }
        }
        var beta: String?
        let fallbackModels = ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
        if provider.refusalFallbacks ?? true, fallbackModels.contains(model) {
            b["fallbacks"] = "default"
            beta = "server-side-fallback-2026-07-01"
        }
        return (b, beta)
    }
}

// MARK: - Upstream events

enum UpstreamEvent {
    case text(String)
    case thinking(String)
    case toolStart(index: Int, id: String, name: String)
    case toolArgs(index: Int, String)
    case finish(String)            // OpenAI finish_reason vocabulary
    case usage(prompt: Int?, completion: Int?)
    case model(String)
    case error(String)
}

/// Anthropic Messages SSE / JSON → events.
struct AnthropicParser {
    private var toolIndex: [Int: Int] = [:]
    private var promptTokens: Int?

    static func finishReason(_ s: String?) -> String {
        switch s {
        case "max_tokens": return "length"
        case "tool_use": return "tool_calls"
        case "refusal": return "content_filter"
        default: return "stop"
        }
    }

    mutating func feed(line: String) -> [UpstreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let o = JSON.object(Data(payload.utf8)) else { return [] }
        switch o["type"] as? String {
        case "message_start":
            let msg = o["message"] as? [String: Any] ?? [:]
            let u = msg["usage"] as? [String: Any] ?? [:]
            promptTokens = (JSON.int(u["input_tokens"]) ?? 0) + (JSON.int(u["cache_read_input_tokens"]) ?? 0) + (JSON.int(u["cache_creation_input_tokens"]) ?? 0)
            var ev: [UpstreamEvent] = [.usage(prompt: promptTokens, completion: nil)]
            if let m = msg["model"] as? String { ev.append(.model(m)) }
            return ev
        case "content_block_start":
            let idx = JSON.int(o["index"]) ?? 0
            let block = o["content_block"] as? [String: Any] ?? [:]
            if block["type"] as? String == "tool_use" {
                let ti = toolIndex.count
                toolIndex[idx] = ti
                return [.toolStart(index: ti, id: block["id"] as? String ?? "toolu_\(ti)", name: block["name"] as? String ?? "")]
            }
            if let t = block["text"] as? String, !t.isEmpty { return [.text(t)] }
            return []
        case "content_block_delta":
            let idx = JSON.int(o["index"]) ?? 0
            let d = o["delta"] as? [String: Any] ?? [:]
            switch d["type"] as? String {
            case "text_delta": return [.text(d["text"] as? String ?? "")]
            case "thinking_delta": return [.thinking(d["thinking"] as? String ?? "")]
            case "input_json_delta": return [.toolArgs(index: toolIndex[idx] ?? 0, d["partial_json"] as? String ?? "")]
            default: return []
            }
        case "message_delta":
            let d = o["delta"] as? [String: Any] ?? [:]
            let u = o["usage"] as? [String: Any] ?? [:]
            var ev: [UpstreamEvent] = [.usage(prompt: promptTokens, completion: JSON.int(u["output_tokens"]))]
            if let r = d["stop_reason"] as? String { ev.append(.finish(AnthropicParser.finishReason(r))) }
            return ev
        case "error":
            let e = o["error"] as? [String: Any] ?? [:]
            return [.error(e["message"] as? String ?? "upstream error")]
        default:
            return []
        }
    }

    static func full(_ o: [String: Any]) -> [UpstreamEvent] {
        var ev: [UpstreamEvent] = []
        if let m = o["model"] as? String { ev.append(.model(m)) }
        var ti = 0
        for b in o["content"] as? [[String: Any]] ?? [] {
            switch b["type"] as? String {
            case "text": ev.append(.text(b["text"] as? String ?? ""))
            case "thinking": if let t = b["thinking"] as? String, !t.isEmpty { ev.append(.thinking(t)) }
            case "tool_use":
                ev.append(.toolStart(index: ti, id: b["id"] as? String ?? "toolu_\(ti)", name: b["name"] as? String ?? ""))
                ev.append(.toolArgs(index: ti, CanonRequest.argumentsString(b["input"] ?? [String: Any]())))
                ti += 1
            default: break
            }
        }
        let u = o["usage"] as? [String: Any] ?? [:]
        let prompt = (JSON.int(u["input_tokens"]) ?? 0) + (JSON.int(u["cache_read_input_tokens"]) ?? 0) + (JSON.int(u["cache_creation_input_tokens"]) ?? 0)
        ev.append(.usage(prompt: prompt, completion: JSON.int(u["output_tokens"])))
        ev.append(.finish(finishReason(o["stop_reason"] as? String)))
        return ev
    }
}

/// OpenAI-compatible SSE / JSON → events (used when an Ollama-format client talks to an OpenAI provider).
struct OpenAIParser {
    private var seenTools = Set<Int>()

    mutating func feed(line: String) -> [UpstreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let o = JSON.object(Data(payload.utf8)) else { return [] }
        if let e = o["error"] { return [.error(OpenAIParser.message(e))] }
        var ev: [UpstreamEvent] = []
        if let m = o["model"] as? String { ev.append(.model(m)) }
        for c in o["choices"] as? [[String: Any]] ?? [] {
            let d = c["delta"] as? [String: Any] ?? [:]
            if let r = (d["reasoning_content"] as? String) ?? (d["reasoning"] as? String), !r.isEmpty { ev.append(.thinking(r)) }
            if let t = d["content"] as? String, !t.isEmpty { ev.append(.text(t)) }
            for tc in d["tool_calls"] as? [[String: Any]] ?? [] {
                let i = JSON.int(tc["index"]) ?? 0
                let fn = tc["function"] as? [String: Any] ?? [:]
                if !seenTools.contains(i) {
                    seenTools.insert(i)
                    ev.append(.toolStart(index: i, id: tc["id"] as? String ?? "call_\(i)", name: fn["name"] as? String ?? ""))
                }
                if let a = fn["arguments"] as? String, !a.isEmpty { ev.append(.toolArgs(index: i, a)) }
            }
            if let f = c["finish_reason"] as? String { ev.append(.finish(f)) }
        }
        if let u = o["usage"] as? [String: Any] {
            ev.append(.usage(prompt: JSON.int(u["prompt_tokens"]), completion: JSON.int(u["completion_tokens"])))
        }
        return ev
    }

    static func full(_ o: [String: Any]) -> [UpstreamEvent] {
        var ev: [UpstreamEvent] = []
        if let m = o["model"] as? String { ev.append(.model(m)) }
        let c = (o["choices"] as? [[String: Any]])?.first ?? [:]
        let msg = c["message"] as? [String: Any] ?? [:]
        if let r = (msg["reasoning_content"] as? String) ?? (msg["reasoning"] as? String), !r.isEmpty { ev.append(.thinking(r)) }
        if let t = (msg["content"] as? String) ?? (c["text"] as? String), !t.isEmpty { ev.append(.text(t)) }
        for (i, tc) in (msg["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
            let fn = tc["function"] as? [String: Any] ?? [:]
            ev.append(.toolStart(index: i, id: tc["id"] as? String ?? "call_\(i)", name: fn["name"] as? String ?? ""))
            ev.append(.toolArgs(index: i, CanonRequest.argumentsString(fn["arguments"])))
        }
        if let u = o["usage"] as? [String: Any] {
            ev.append(.usage(prompt: JSON.int(u["prompt_tokens"]), completion: JSON.int(u["completion_tokens"])))
        }
        ev.append(.finish(c["finish_reason"] as? String ?? "stop"))
        return ev
    }

    static func message(_ e: Any) -> String {
        if let s = e as? String { return s }
        if let d = e as? [String: Any] { return d["message"] as? String ?? "\(d)" }
        return "\(e)"
    }
}

// MARK: - Client-format encoder

/// Re-encodes upstream events in the format the client asked for and keeps the counters for telemetry.
final class ClientEncoder {
    let kind: EndpointKind
    let model: String
    let clientWantsUsage: Bool
    let startMs: Double
    private let id = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased())"
    private let created = Int(Date().timeIntervalSince1970)
    private var sentRole = false
    private(set) var text = ""
    private(set) var thinking = ""
    private var tools: [Int: (id: String, name: String, args: String)] = [:]
    private(set) var finishReason: String?
    private(set) var promptTokens: Int?
    private(set) var completionTokens: Int?
    private(set) var firstTokenMs: Double?
    private(set) var lastTokenMs: Double?
    private(set) var error: String?

    init(kind: EndpointKind, model: String, clientWantsUsage: Bool, startMs: Double) {
        self.kind = kind; self.model = model; self.clientWantsUsage = clientWantsUsage; self.startMs = startMs
    }

    var contentType: String { kind.isOpenAI ? "text/event-stream; charset=utf-8" : "application/x-ndjson" }

    /// Updates state; returns the bytes to stream for this event (may be empty).
    func encode(_ e: UpstreamEvent) -> [UInt8] {
        let now = monotonicMs()
        switch e {
        case .text(let t):
            guard !t.isEmpty else { return [] }
            mark(now); text += t
            switch kind {
            case .openAIChat: return sse(chunk(delta: ["content": t]))
            case .openAICompletions: return sse(completionChunk(t, finish: nil))
            case .ollamaChat: return ndjson(native(message: ["role": "assistant", "content": t]))
            case .ollamaGenerate: return ndjson(native(response: t))
            }
        case .thinking(let t):
            guard !t.isEmpty else { return [] }
            mark(now); thinking += t
            switch kind {
            case .openAIChat: return sse(chunk(delta: ["reasoning_content": t]))
            case .openAICompletions: return []
            case .ollamaChat: return ndjson(native(message: ["role": "assistant", "content": "", "thinking": t]))
            case .ollamaGenerate: return ndjson(native(response: "", extra: ["thinking": t]))
            }
        case .toolStart(let i, let id, let name):
            mark(now); tools[i] = (id, name, "")
            if kind == .openAIChat {
                return sse(chunk(delta: ["tool_calls": [["index": i, "id": id, "type": "function", "function": ["name": name, "arguments": ""]]]]))
            }
            return []   // Ollama format needs complete arguments: emitted at the end
        case .toolArgs(let i, let a):
            tools[i, default: ("call_\(i)", "", "")].args += a
            if kind == .openAIChat { return sse(chunk(delta: ["tool_calls": [["index": i, "function": ["arguments": a]]]])) }
            return []
        case .finish(let r):
            finishReason = r
            return []
        case .usage(let p, let c):
            if let p { promptTokens = p }
            if let c { completionTokens = c }
            return []
        case .model:
            return []
        case .error(let m):
            error = m
            return kind.isOpenAI ? sse(["error": ["message": m, "type": "upstream_error"]]) : ndjson(["error": m])
        }
    }

    /// Final bytes of a streamed response.
    func finishStream() -> [UInt8] {
        let reason = finishReason ?? (tools.isEmpty ? "stop" : "tool_calls")
        switch kind {
        case .openAIChat:
            var out = sse(chunk(delta: [:], finish: reason))
            if clientWantsUsage { out += sse(usageChunk()) }
            return out + Array("data: [DONE]\n\n".utf8)
        case .openAICompletions:
            var out = sse(completionChunk("", finish: reason))
            if clientWantsUsage { out += sse(usageChunk()) }
            return out + Array("data: [DONE]\n\n".utf8)
        case .ollamaChat:
            var out: [UInt8] = []
            if !tools.isEmpty { out = ndjson(native(message: ["role": "assistant", "content": "", "tool_calls": ollamaToolCalls()])) }
            return out + ndjson(nativeFinal(message: ["role": "assistant", "content": ""]))
        case .ollamaGenerate:
            return ndjson(nativeFinal(response: ""))
        }
    }

    /// Whole response for stream:false.
    func fullResponse() -> [String: Any] {
        let reason = finishReason ?? (tools.isEmpty ? "stop" : "tool_calls")
        switch kind {
        case .openAIChat:
            var msg: [String: Any] = ["role": "assistant", "content": text]
            if !thinking.isEmpty { msg["reasoning_content"] = thinking }
            if !tools.isEmpty {
                msg["tool_calls"] = tools.keys.sorted().map { i -> [String: Any] in
                    let t = tools[i]!
                    return ["id": t.id, "type": "function", "function": ["name": t.name, "arguments": t.args.isEmpty ? "{}" : t.args]]
                }
            }
            return ["id": id, "object": "chat.completion", "created": created, "model": model,
                    "choices": [["index": 0, "message": msg, "finish_reason": reason]], "usage": usage()]
        case .openAICompletions:
            return ["id": id, "object": "text_completion", "created": created, "model": model,
                    "choices": [["index": 0, "text": text, "finish_reason": reason]], "usage": usage()]
        case .ollamaChat:
            var msg: [String: Any] = ["role": "assistant", "content": text]
            if !thinking.isEmpty { msg["thinking"] = thinking }
            if !tools.isEmpty { msg["tool_calls"] = ollamaToolCalls() }
            return nativeFinal(message: msg)
        case .ollamaGenerate:
            var d = nativeFinal(response: text)
            if !thinking.isEmpty { d["thinking"] = thinking }
            return d
        }
    }

    // MARK: helpers

    private func mark(_ now: Double) {
        if firstTokenMs == nil { firstTokenMs = now }
        lastTokenMs = now
    }

    private func chunk(delta: [String: Any], finish: String? = nil) -> [String: Any] {
        var d = delta
        if !sentRole { d["role"] = "assistant"; sentRole = true }
        return ["id": id, "object": "chat.completion.chunk", "created": created, "model": model,
                "choices": [["index": 0, "delta": d, "finish_reason": (finish as Any?) ?? NSNull()]]]
    }

    private func completionChunk(_ t: String, finish: String?) -> [String: Any] {
        ["id": id, "object": "text_completion", "created": created, "model": model,
         "choices": [["index": 0, "text": t, "finish_reason": (finish as Any?) ?? NSNull()]]]
    }

    private func usage() -> [String: Any] {
        ["prompt_tokens": promptTokens ?? 0, "completion_tokens": completionTokens ?? 0,
         "total_tokens": (promptTokens ?? 0) + (completionTokens ?? 0)]
    }

    private func usageChunk() -> [String: Any] {
        ["id": id, "object": kind == .openAIChat ? "chat.completion.chunk" : "text_completion", "created": created,
         "model": model, "choices": [Any](), "usage": usage()]
    }

    private var isoNow: String { ISO8601DateFormatter().string(from: Date()) }

    private func native(message: [String: Any]? = nil, response: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var d: [String: Any] = ["model": model, "created_at": isoNow, "done": false]
        if let message { d["message"] = message }
        if let response { d["response"] = response }
        extra.forEach { d[$0.key] = $0.value }
        return d
    }

    private func nativeFinal(message: [String: Any]? = nil, response: String? = nil) -> [String: Any] {
        let end = monotonicMs()
        var d = native(message: message, response: response)
        d["done"] = true
        d["done_reason"] = (finishReason == "length") ? "length" : "stop"
        d["total_duration"] = Int((end - startMs) * 1e6)
        d["load_duration"] = 0
        if let p = promptTokens { d["prompt_eval_count"] = p }
        if let c = completionTokens { d["eval_count"] = c }
        if let f = firstTokenMs {
            d["prompt_eval_duration"] = Int((f - startMs) * 1e6)
            d["eval_duration"] = Int(max(1, (lastTokenMs ?? f) - f) * 1e6)
        }
        return d
    }

    private func ollamaToolCalls() -> [[String: Any]] {
        tools.keys.sorted().map { i in
            let t = tools[i]!
            let args = (try? JSONSerialization.jsonObject(with: Data((t.args.isEmpty ? "{}" : t.args).utf8))) ?? [String: Any]()
            return ["id": t.id, "function": ["name": t.name, "arguments": args]]
        }
    }

    private func sse(_ o: [String: Any]) -> [UInt8] {
        Array("data: ".utf8) + Array((try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)) + Array("\n\n".utf8)
    }

    private func ndjson(_ o: [String: Any]) -> [UInt8] {
        Array((try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)) + [0x0A]
    }

    func fill(_ r: inout RequestRecord, endMs: Double, streamed: Bool) {
        r.promptTokens = promptTokens
        r.completionTokens = completionTokens
        r.totalMs = endMs - startMs
        r.timingSource = "gateway"
        if let f = firstTokenMs, let l = lastTokenMs, l > f, let c = completionTokens, c > 1 {
            r.evalMs = l - f
            r.tokensPerSec = Double(c - 1) / ((l - f) / 1000)
        }
        if streamed, let f = firstTokenMs { r.ttftMs = f - startMs }
        if let e = error { r.error = e }
    }
}

// MARK: - Gateway integration

extension InferenceGateway {
    /// Inference against a remote provider. No admission slot or memory breaker: the work runs elsewhere.
    func remoteInference(_ req: GatewayRequest, _ w: ResponseWriter, kind: EndpointKind, json: [String: Any],
                         provider p: ProviderConfig, model: String, cors: [(String, String)], start: Double) async {
        let client = InferenceGateway.clientApp(req.headers)
        let stream = (json["stream"] as? Bool) ?? kind.defaultStream
        let label = "\(p.id)/\(model)"
        app.tracker.remoteBegan(p.id)
        defer { app.tracker.remoteEnded(p.id) }
        var record = RequestRecord(clientApp: client, endpoint: kind.rawValue, model: label, stream: stream, priority: "remote")
        let extra = cors + [("X-LocalLLM-Model", label), ("X-LocalLLM-Provider", p.id), ("X-LocalLLM-Queue-Ms", "0.0")]

        guard !model.isEmpty else {
            record.status = 400; record.error = "no model"; app.tracker.record(record)
            await sendError(w, kind, .badRequest, "el proveedor \(p.id) no tiene modelo predeterminado; usa \"\(p.id)/<modelo>\"", cors)
            return
        }
        guard let base = p.resolvedBaseURL else {
            await sendError(w, kind, .badRequest, "baseUrl no válida para \(p.id)", cors); return
        }

        // OpenAI client → OpenAI-compatible provider: relay without translation (tools, logprobs… intact).
        if p.type == .openai && kind.isOpenAI {
            var body = json
            body["model"] = model
            var clientWantsUsage = false
            if stream {
                var so = body["stream_options"] as? [String: Any] ?? [:]
                clientWantsUsage = so["include_usage"] as? Bool ?? false
                so["include_usage"] = true
                body["stream_options"] = so
            }
            let path = kind == .openAIChat ? "chat/completions" : "completions"
            let up = makeRequest(p, url: base.appendingPathComponent(path), body: body)
            await relayOpenAI(up, p, w, kind: kind, stream: stream, clientWantsUsage: clientWantsUsage,
                              record: &record, extra: extra, cors: cors, start: start)
            app.tracker.record(record)
            return
        }

        let canon = kind.isOpenAI ? CanonRequest.fromOpenAI(json, kind: kind, stream: stream)
                                  : CanonRequest.fromOllama(json, kind: kind, stream: stream)
        let up: URLRequest
        var anthropic = AnthropicParser()
        var openai = OpenAIParser()
        if p.type == .anthropic {
            let (body, beta) = canon.anthropicBody(model: model, provider: p)
            var r = makeRequest(p, url: base.appendingPathComponent("v1/messages"), body: body)
            if let beta { r.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
            up = r
        } else {
            up = makeRequest(p, url: base.appendingPathComponent("chat/completions"), body: canon.openAIBody(model: model, provider: p))
        }
        let clientWantsUsage = ((json["stream_options"] as? [String: Any])?["include_usage"] as? Bool) ?? false
        let enc = ClientEncoder(kind: kind, model: label, clientWantsUsage: clientWantsUsage, startMs: start)
        let session = app.providers.session(for: p)

        do {
            if !stream {
                let (data, resp) = try await session.data(for: up)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
                record.status = status
                guard status < 400, let obj = JSON.object(data) else {
                    let msg = upstreamMessage(data, status: status, provider: p)
                    record.error = msg; record.totalMs = monotonicMs() - start
                    app.tracker.record(record)
                    await sendError(w, kind, HTTPResponseStatus(statusCode: status), msg, extra)
                    return
                }
                let events = p.type == .anthropic ? AnthropicParser.full(obj) : OpenAIParser.full(obj)
                events.forEach { _ = enc.encode($0) }
                enc.fill(&record, endMs: monotonicMs(), streamed: false)
                await w.sendJSON(.ok, enc.fullResponse(), headers: extra)
            } else {
                let (bytes, resp) = try await session.bytes(for: up)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
                record.status = status
                if status >= 400 {
                    var data = Data()
                    for try await b in bytes { data.append(b); if data.count > 65_536 { break } }
                    let msg = upstreamMessage(data, status: status, provider: p)
                    record.error = msg; record.totalMs = monotonicMs() - start
                    app.tracker.record(record)
                    await sendError(w, kind, HTTPResponseStatus(statusCode: status), msg, extra)
                    return
                }
                try await w.startStream(status: .ok, headers: extra + [("Content-Type", enc.contentType)])
                for try await line in bytes.lines {
                    let events = p.type == .anthropic ? anthropic.feed(line: line) : openai.feed(line: line)
                    for e in events {
                        let out = enc.encode(e)
                        if !out.isEmpty { try await w.write(out) }
                    }
                }
                try await w.write(enc.finishStream())
                enc.fill(&record, endMs: monotonicMs(), streamed: true)
                await w.finish()
            }
        } catch {
            let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled || !w.isActive
            enc.fill(&record, endMs: monotonicMs(), streamed: stream)
            record.status = cancelled ? 499 : 502
            record.error = cancelled ? "client disconnected" : "\(p.id): \(error.localizedDescription)"
            if !w.headSent && !cancelled {
                await sendError(w, kind, .badGateway, "\(p.name) no disponible: \(error.localizedDescription)", cors)
            } else if w.headSent { w.abort() }
        }
        app.tracker.record(record)
    }

    func makeRequest(_ p: ProviderConfig, url: URL, body: [String: Any]?, method: String = "POST") -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = p.apiKey, !key.isEmpty {
            if p.type == .anthropic { r.setValue(key, forHTTPHeaderField: "x-api-key") }
            else { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        if p.type == .anthropic { r.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version") }
        for (k, v) in p.headers ?? [:] { r.setValue(v, forHTTPHeaderField: k) }
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }

    private func upstreamMessage(_ data: Data, status: Int, provider p: ProviderConfig) -> String {
        if let o = JSON.object(data), let e = o["error"] { return "\(p.name): \(OpenAIParser.message(e))" }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(p.name): HTTP \(status)\(text.isEmpty ? "" : " — \(text)")"
    }

    /// Byte relay for OpenAI → OpenAI-compatible, with exact usage extraction (same as the local path).
    private func relayOpenAI(_ up: URLRequest, _ p: ProviderConfig, _ w: ResponseWriter, kind: EndpointKind, stream: Bool,
                             clientWantsUsage: Bool, record: inout RequestRecord, extra: [(String, String)],
                             cors: [(String, String)], start: Double) async {
        var usage = UsageExtractor(kind: kind, startMs: start)
        let session = app.providers.session(for: p)
        do {
            if !stream {
                let (data, resp) = try await session.data(for: up)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
                record.status = status
                if let obj = JSON.object(data) {
                    usage.absorbOpenAINonStream(obj)
                    if status >= 400 { record.error = upstreamMessage(data, status: status, provider: p) }
                }
                usage.fill(&record, endMs: monotonicMs(), streamed: false)
                await w.send(status: HTTPResponseStatus(statusCode: status), headers: extra + [("Content-Type", contentType(resp))], body: data)
            } else {
                let (bytes, resp) = try await session.bytes(for: up)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
                record.status = status
                try await w.startStream(status: HTTPResponseStatus(statusCode: status), headers: extra + [("Content-Type", contentType(resp))])
                var line: [UInt8] = []
                var dropNextBlank = false
                for try await byte in bytes {
                    line.append(byte)
                    guard byte == 0x0A else { continue }
                    let isBlank = line.count <= 2 && (line.first == 0x0A || line.first == 0x0D)
                    if isBlank && dropNextBlank {
                        dropNextBlank = false
                    } else if usage.consume(line: line, now: monotonicMs(), clientWantsUsage: clientWantsUsage) {
                        dropNextBlank = true
                    } else {
                        try await w.write(line)
                    }
                    line.removeAll(keepingCapacity: true)
                }
                if !line.isEmpty { _ = usage.consume(line: line, now: monotonicMs(), clientWantsUsage: clientWantsUsage); try await w.write(line) }
                usage.fill(&record, endMs: monotonicMs(), streamed: true)
                await w.finish()
            }
        } catch {
            let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled || !w.isActive
            usage.fill(&record, endMs: monotonicMs(), streamed: stream)
            record.status = cancelled ? 499 : 502
            record.error = cancelled ? "client disconnected" : "\(p.id): \(error.localizedDescription)"
            if !w.headSent && !cancelled {
                await sendError(w, kind, .badGateway, "\(p.name) no disponible: \(error.localizedDescription)", cors)
            } else if w.headSent { w.abort() }
        }
    }

    // MARK: Model listing / connection test

    func listRemoteModels(_ p: ProviderConfig) async -> (ok: Bool, status: Int, models: [String], detail: String) {
        guard let base = p.resolvedBaseURL else { return (false, 0, [], "baseUrl no válida") }
        let url = p.type == .anthropic ? base.appendingPathComponent("v1/models") : base.appendingPathComponent("models")
        var r = makeRequest(p, url: url, body: nil, method: "GET")
        if p.type == .anthropic, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.queryItems = [URLQueryItem(name: "limit", value: "100")]
            r.url = c.url
        }
        r.timeoutInterval = 15
        do {
            let (data, resp) = try await app.providers.session(for: p).data(for: r)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status < 400 else { return (false, status, [], upstreamMessage(data, status: status, provider: p)) }
            let ids = ((JSON.object(data)?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
            return (true, status, ids, "conexión correcta: \(ids.count) modelo(s)")
        } catch {
            return (false, 0, [], error.localizedDescription)
        }
    }

    /// `/v1/models`: local Ollama models plus `<provider>/<model>` for every enabled remote provider.
    func mergedModelList(local data: Data) -> Data {
        var obj = JSON.object(data) ?? ["object": "list", "data": [Any]()]
        var list = obj["data"] as? [[String: Any]] ?? []
        for p in app.providers.current.providers where p.enabled && !p.isLocal {
            for m in p.offeredModels { list.append(["id": "\(p.id)/\(m)", "object": "model", "created": 0, "owned_by": p.id]) }
        }
        obj["data"] = list
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? data
    }
}
