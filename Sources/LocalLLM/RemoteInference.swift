import Foundation
import NIOHTTP1

// MARK: - Remote inference (OpenAI-compatible APIs)
//
// Every remote provider is spoken to through the OpenAI wire format. OpenAI endpoints are
// forwarded as-is; Ollama-native /api/chat and /api/generate are translated both ways so apps
// built on the `ollama` libraries (and the dashboard chat) keep working when the active model
// is an API model. Remote calls skip the RAM breaker and the local slot queue: they don't use
// this Mac's memory.

extension InferenceGateway {

    func remoteInference(_ req: GatewayRequest, _ w: ResponseWriter, kind: EndpointKind, json: [String: Any],
                         provider: RemoteProvider, model: String, stream: Bool, client: String,
                         start: Double, cors: [(String, String)]) async {
        let display = "\(provider.id)/\(model)"
        let cfg = app.config.current
        let priority = RequestPriority(header: req.headers.first(name: "X-Priority") ?? cfg.routing.clientPriorities[client])
        var record = RequestRecord(clientApp: client, endpoint: kind.rawValue, model: display, stream: stream, priority: priority.description)
        record.timingSource = "remote"

        guard provider.resolvedKey != nil || provider.base?.host == "127.0.0.1" || provider.base?.host == "localhost" else {
            record.status = 401; record.error = "provider \(provider.id) has no API key"; record.totalMs = monotonicMs() - start
            app.tracker.record(record)
            await sendError(w, kind, .unauthorized, "el proveedor \(provider.id) no tiene API key configurada", cors)
            return
        }

        let body: [String: Any]
        let path: String
        if kind.isOpenAI {
            var b = json
            b["model"] = model
            b.removeValue(forKey: "options"); b.removeValue(forKey: "keep_alive")
            if stream {
                var so = b["stream_options"] as? [String: Any] ?? [:]
                so["include_usage"] = true
                b["stream_options"] = so
            }
            body = b
            path = kind == .openAIChat ? "/chat/completions" : "/completions"
        } else {
            body = OllamaBridge.openAIRequest(fromNative: json, kind: kind, model: model, stream: stream)
            path = "/chat/completions"
        }
        let clientWantsUsage = kind.isOpenAI && ((json["stream_options"] as? [String: Any])?["include_usage"] as? Bool ?? false)

        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let up = app.providers.request(provider, path: path, body: data) else {
            await sendError(w, kind, .badRequest, "baseURL inválida para \(provider.id)", cors)
            return
        }
        var usage = UsageExtractor(kind: .openAIChat, startMs: start)
        let extra = cors + [("X-LocalLLM-Model", display), ("X-LocalLLM-Provider", provider.id), ("X-LocalLLM-Queue-Ms", "0.0")]

        do {
            if !stream {
                let (data, resp) = try await upstream.data(for: up)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
                record.status = status
                let obj = JSON.object(data)
                if let obj { usage.absorbOpenAINonStream(obj) }
                usage.fill(&record, endMs: monotonicMs(), streamed: false)
                if status >= 400 {
                    let msg = OllamaBridge.errorMessage(obj, data)
                    record.error = "\(provider.id): \(msg)"
                    if kind.isOpenAI {
                        await w.send(status: HTTPResponseStatus(statusCode: status), headers: extra + [("Content-Type", contentType(resp))], body: data)
                    } else {
                        await w.sendJSON(HTTPResponseStatus(statusCode: status), ["error": "\(provider.id): \(msg)"], headers: extra)
                    }
                } else if kind.isOpenAI {
                    await w.send(status: .ok, headers: extra + [("Content-Type", contentType(resp))], body: data)
                } else {
                    let native = OllamaBridge.nativeResponse(fromOpenAI: obj ?? [:], kind: kind, model: display,
                                                             totalMs: record.totalMs)
                    await w.sendJSON(.ok, native, headers: extra)
                }
            } else {
                let (bytes, resp) = try await upstream.bytes(for: up)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
                record.status = status
                if status >= 400 {
                    var buf = Data()
                    for try await b in bytes { buf.append(b); if buf.count > 65_536 { break } }
                    let msg = OllamaBridge.errorMessage(JSON.object(buf), buf)
                    record.error = "\(provider.id): \(msg)"
                    usage.fill(&record, endMs: monotonicMs(), streamed: true)
                    if kind.isOpenAI {
                        await w.send(status: HTTPResponseStatus(statusCode: status), headers: extra + [("Content-Type", contentType(resp))], body: buf)
                    } else {
                        await w.sendJSON(HTTPResponseStatus(statusCode: status), ["error": "\(provider.id): \(msg)"], headers: extra)
                    }
                    app.tracker.record(record)
                    return
                }
                let ctype = kind.isOpenAI ? "text/event-stream" : "application/x-ndjson"
                try await w.startStream(status: .ok, headers: extra + [("Content-Type", ctype)])
                var bridge = OllamaBridge.StreamTranslator(kind: kind, model: display, startMs: start)
                var line: [UInt8] = []
                line.reserveCapacity(2048)
                var dropNextBlank = false
                func handle(_ l: [UInt8]) async throws {
                    let now = monotonicMs()
                    if kind.isOpenAI {
                        let isBlank = l.count <= 2 && (l.first == 0x0A || l.first == 0x0D)
                        if isBlank && dropNextBlank { dropNextBlank = false; return }
                        if usage.consume(line: l, now: now, clientWantsUsage: clientWantsUsage) { dropNextBlank = true; return }
                        try await w.write(l)
                    } else {
                        _ = usage.consume(line: l, now: now, clientWantsUsage: true)
                        for out in bridge.consume(sseLine: l, now: now) { try await w.write(out) }
                    }
                }
                for try await byte in bytes {
                    line.append(byte)
                    guard byte == 0x0A else { continue }
                    try await handle(line)
                    line.removeAll(keepingCapacity: true)
                }
                if !line.isEmpty { line.append(0x0A); try await handle(line) }
                if !kind.isOpenAI {
                    for out in bridge.finish(now: monotonicMs(), promptTokens: usage.promptTokens,
                                             completionTokens: usage.completionTokens) { try await w.write(out) }
                }
                usage.fill(&record, endMs: monotonicMs(), streamed: true)
                await w.finish()
            }
        } catch {
            let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled || !w.isActive
            usage.fill(&record, endMs: monotonicMs(), streamed: stream)
            record.status = cancelled ? 499 : 502
            record.error = cancelled ? "client disconnected" : "\(provider.id): \(error.localizedDescription)"
            if !w.headSent && !cancelled {
                await sendError(w, kind, .badGateway, "\(provider.id) no disponible: \(error.localizedDescription)", cors)
            } else if w.headSent { w.abort() }
        }
        app.tracker.record(record)
    }

    // MARK: /v1/models — local Ollama models + every configured remote model

    func listModels(_ w: ResponseWriter, cors: [(String, String)]) async {
        var data: [[String: Any]] = []
        var r = URLRequest(url: app.ollama.baseURL.appendingPathComponent("v1/models"))
        r.timeoutInterval = 5
        if let (d, _) = try? await upstream.data(for: r), let obj = JSON.object(d), let list = obj["data"] as? [[String: Any]] {
            data = list
        }
        let now = Int(Date().timeIntervalSince1970)
        let active = app.activeTarget.displayName
        data.insert(["id": "default", "object": "model", "created": now, "owned_by": "localllm", "root": active], at: 0)
        for p in app.providers.enabled {
            for m in p.models { data.append(["id": "\(p.id)/\(m)", "object": "model", "created": now, "owned_by": p.id]) }
        }
        await w.sendJSON(.ok, ["object": "list", "data": data], headers: cors)
    }

    // MARK: /v1/embeddings — remote when the model belongs to a provider

    func embeddings(_ req: GatewayRequest, _ w: ResponseWriter, cors: [(String, String)]) async {
        guard var obj = JSON.object(req.body), let m = obj["model"] as? String,
              case .remote(let p, let model) = app.resolveTarget(m),
              // "default"/aliases on a remote chat model stay local: chat APIs rarely embed.
              app.providers.split(m) != nil || app.providers.owner(ofBare: m) != nil else {
            await passthrough(req, w, cors: cors)
            return
        }
        obj["model"] = model
        guard let body = try? JSONSerialization.data(withJSONObject: obj),
              let up = app.providers.request(p, path: "/embeddings", body: body) else {
            await sendError(w, .openAIChat, .badRequest, "baseURL inválida para \(p.id)", cors)
            return
        }
        do {
            let (d, resp) = try await upstream.data(for: up)
            await w.send(status: HTTPResponseStatus(statusCode: (resp as? HTTPURLResponse)?.statusCode ?? 502),
                         headers: cors + [("Content-Type", contentType(resp)), ("X-LocalLLM-Provider", p.id)], body: d)
        } catch {
            await sendError(w, .openAIChat, .badGateway, "\(p.id) no disponible: \(error.localizedDescription)", cors)
        }
    }
}

// MARK: - Ollama native <-> OpenAI translation

enum OllamaBridge {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func errorMessage(_ obj: [String: Any]?, _ raw: Data) -> String {
        if let e = obj?["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let e = obj?["error"] as? String { return e }
        if let m = obj?["message"] as? String { return m }
        if let arr = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]],
           let e = arr.first?["error"] as? [String: Any], let m = e["message"] as? String { return m }   // Gemini wraps in an array
        return String(data: raw.prefix(400), encoding: .utf8) ?? "upstream error"
    }

    private static func imagePart(_ b64: String) -> [String: Any] {
        let mime = b64.hasPrefix("/9j") ? "image/jpeg" : b64.hasPrefix("R0lG") ? "image/gif" : b64.hasPrefix("UklG") ? "image/webp" : "image/png"
        let url = b64.hasPrefix("data:") ? b64 : "data:\(mime);base64,\(b64)"
        return ["type": "image_url", "image_url": ["url": url]]
    }

    private static func content(_ text: String, _ images: [String]?) -> Any {
        guard let images, !images.isEmpty else { return text }
        var parts: [[String: Any]] = []
        if !text.isEmpty { parts.append(["type": "text", "text": text]) }
        parts += images.map(imagePart)
        return parts
    }

    static func openAIRequest(fromNative json: [String: Any], kind: EndpointKind, model: String, stream: Bool) -> [String: Any] {
        var messages: [[String: Any]] = []
        if kind == .ollamaGenerate {
            if let sys = json["system"] as? String, !sys.isEmpty { messages.append(["role": "system", "content": sys]) }
            messages.append(["role": "user", "content": content(json["prompt"] as? String ?? "", json["images"] as? [String])])
        } else {
            var callCounter = 0
            var pendingIds: [String] = []
            for m in json["messages"] as? [[String: Any]] ?? [] {
                let role = m["role"] as? String ?? "user"
                var out: [String: Any] = ["role": role]
                out["content"] = content(m["content"] as? String ?? "", m["images"] as? [String])
                if role == "assistant", let calls = m["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    out["tool_calls"] = calls.map { c -> [String: Any] in
                        callCounter += 1
                        let id = "call_\(callCounter)"
                        pendingIds.append(id)
                        let f = c["function"] as? [String: Any] ?? [:]
                        let args: String
                        if let s = f["arguments"] as? String { args = s }
                        else { args = String(data: (try? JSONSerialization.data(withJSONObject: f["arguments"] ?? [:])) ?? Data("{}".utf8), encoding: .utf8) ?? "{}" }
                        return ["id": id, "type": "function", "function": ["name": f["name"] ?? "", "arguments": args]]
                    }
                }
                if role == "tool" {
                    out["tool_call_id"] = pendingIds.isEmpty ? "call_\(max(1, callCounter))" : pendingIds.removeFirst()
                    if let n = m["tool_name"] as? String { out["name"] = n }
                }
                messages.append(out)
            }
        }
        var body: [String: Any] = ["model": model, "messages": messages, "stream": stream]
        if stream { body["stream_options"] = ["include_usage": true] }
        if let tools = json["tools"] as? [Any], !tools.isEmpty { body["tools"] = tools }
        let o = json["options"] as? [String: Any] ?? [:]
        for (src, dst) in [("temperature", "temperature"), ("top_p", "top_p"), ("seed", "seed"),
                           ("presence_penalty", "presence_penalty"), ("frequency_penalty", "frequency_penalty"), ("stop", "stop")] {
            if let v = o[src] { body[dst] = v }
        }
        if let n = JSON.int(o["num_predict"]), n > 0 { body["max_tokens"] = n }
        if let f = json["format"] as? String, f == "json" {
            body["response_format"] = ["type": "json_object"]
        } else if let schema = json["format"] as? [String: Any] {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "response", "schema": schema]]
        }
        return body
    }

    /// OpenAI tool_calls (arguments as JSON string) → Ollama (arguments as object).
    static func nativeToolCalls(_ calls: [[String: Any]]) -> [[String: Any]] {
        calls.map { c in
            let f = c["function"] as? [String: Any] ?? [:]
            let argStr = f["arguments"] as? String ?? "{}"
            let args = (try? JSONSerialization.jsonObject(with: Data(argStr.utf8))) ?? [:]
            return ["function": ["name": f["name"] ?? "", "arguments": args]]
        }
    }

    static func reasoning(_ m: [String: Any]?) -> String? {
        (m?["reasoning_content"] as? String) ?? (m?["reasoning"] as? String)
    }

    static func nativeResponse(fromOpenAI obj: [String: Any], kind: EndpointKind, model: String, totalMs: Double) -> [String: Any] {
        let choice = (obj["choices"] as? [[String: Any]])?.first ?? [:]
        let msg = choice["message"] as? [String: Any]
        let text = msg?["content"] as? String ?? ""
        let usage = obj["usage"] as? [String: Any] ?? [:]
        var out: [String: Any] = [
            "model": model, "created_at": iso.string(from: Date()), "done": true,
            "done_reason": (choice["finish_reason"] as? String).map { $0 == "length" ? "length" : "stop" } ?? "stop",
            "total_duration": Int(totalMs * 1e6),
            "prompt_eval_count": JSON.int(usage["prompt_tokens"]) ?? 0,
            "eval_count": JSON.int(usage["completion_tokens"]) ?? 0,
        ]
        if kind == .ollamaGenerate {
            out["response"] = text
            if let r = reasoning(msg), !r.isEmpty { out["thinking"] = r }
        } else {
            var m: [String: Any] = ["role": "assistant", "content": text]
            if let r = reasoning(msg), !r.isEmpty { m["thinking"] = r }
            if let calls = msg?["tool_calls"] as? [[String: Any]], !calls.isEmpty { m["tool_calls"] = nativeToolCalls(calls) }
            out["message"] = m
        }
        return out
    }

    /// SSE chat.completion.chunk lines → Ollama NDJSON lines.
    struct StreamTranslator {
        let kind: EndpointKind
        let model: String
        let startMs: Double
        var firstMs: Double?
        var lastMs: Double?
        var finishReason: String?
        var finished = false
        /// index → (name, arguments-so-far)
        var toolCalls: [Int: (name: String, args: String)] = [:]

        init(kind: EndpointKind, model: String, startMs: Double) { self.kind = kind; self.model = model; self.startMs = startMs }

        private func line(_ obj: [String: Any]) -> [UInt8] {
            var d = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
            d.append(0x0A)
            return [UInt8](d)
        }

        private func chunk(content: String, thinking: String?) -> [String: Any] {
            var o: [String: Any] = ["model": model, "created_at": OllamaBridge.iso.string(from: Date()), "done": false]
            if kind == .ollamaGenerate {
                o["response"] = content
                if let thinking { o["thinking"] = thinking }
            } else {
                var m: [String: Any] = ["role": "assistant", "content": content]
                if let thinking { m["thinking"] = thinking }
                o["message"] = m
            }
            return o
        }

        mutating func consume(sseLine raw: [UInt8], now: Double) -> [[UInt8]] {
            guard raw.starts(with: Array("data:".utf8)) else { return [] }
            let payload = String(decoding: raw.dropFirst(5), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" || payload.isEmpty { return [] }
            guard let obj = JSON.object(Data(payload.utf8)) else { return [] }
            if obj["error"] != nil {
                finished = true
                return [line(["error": OllamaBridge.errorMessage(obj, Data(payload.utf8))])]
            }
            var out: [[UInt8]] = []
            for choice in obj["choices"] as? [[String: Any]] ?? [] {
                let delta = choice["delta"] as? [String: Any]
                let text = delta?["content"] as? String ?? ""
                let think = OllamaBridge.reasoning(delta)
                if !text.isEmpty || !(think ?? "").isEmpty {
                    if firstMs == nil { firstMs = now }
                    lastMs = now
                    out.append(line(chunk(content: text, thinking: (think ?? "").isEmpty ? nil : think)))
                }
                for tc in delta?["tool_calls"] as? [[String: Any]] ?? [] {
                    let i = JSON.int(tc["index"]) ?? toolCalls.count
                    let f = tc["function"] as? [String: Any] ?? [:]
                    var cur = toolCalls[i] ?? ("", "")
                    if let n = f["name"] as? String, !n.isEmpty { cur.name = n }
                    if let a = f["arguments"] as? String { cur.args += a }
                    toolCalls[i] = cur
                }
                if let fr = choice["finish_reason"] as? String { finishReason = fr }
            }
            return out
        }

        mutating func finish(now: Double, promptTokens: Int?, completionTokens: Int?) -> [[UInt8]] {
            guard !finished else { return [] }
            finished = true
            var out: [[UInt8]] = []
            if !toolCalls.isEmpty, kind == .ollamaChat {
                let calls = toolCalls.sorted { $0.key < $1.key }.map { _, v -> [String: Any] in
                    ["function": ["name": v.name, "arguments": v.args.isEmpty ? "{}" : v.args]]
                }
                var o = chunk(content: "", thinking: nil)
                var m = o["message"] as? [String: Any] ?? [:]
                m["tool_calls"] = OllamaBridge.nativeToolCalls(calls)
                o["message"] = m
                out.append(line(o))
            }
            var done = chunk(content: "", thinking: nil)
            done["done"] = true
            done["done_reason"] = finishReason == "length" ? "length" : "stop"
            done["total_duration"] = Int((now - startMs) * 1e6)
            done["prompt_eval_count"] = promptTokens ?? 0
            done["eval_count"] = completionTokens ?? 0
            if let f = firstMs {
                done["prompt_eval_duration"] = Int((f - startMs) * 1e6)          // time to first token
                if let l = lastMs, l > f { done["eval_duration"] = Int((l - f) * 1e6) }
            }
            out.append(line(done))
            return out
        }
    }
}
