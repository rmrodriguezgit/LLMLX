import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

// MARK: - Request / response plumbing

struct GatewayRequest {
    let method: HTTPMethod
    let uri: String
    let headers: HTTPHeaders
    let body: Data

    var path: String { String(uri.split(separator: "?", maxSplits: 1).first ?? "/") }
    var query: [String: String] {
        guard let q = uri.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            out[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return out
    }
}

/// Thread-safe writer used from async tasks; every write awaits the NIO write promise,
/// which gives natural back-pressure when a client reads slowly.
final class ResponseWriter: @unchecked Sendable {
    private let channel: Channel
    private let keepAlive: Bool
    private let version: HTTPVersion
    private(set) var headSent = false

    init(channel: Channel, keepAlive: Bool, version: HTTPVersion) {
        self.channel = channel
        self.keepAlive = keepAlive
        self.version = version
    }

    var isActive: Bool { channel.isActive }

    private func baseHeaders(_ extra: [(String, String)]) -> HTTPHeaders {
        var h = HTTPHeaders(extra)
        h.replaceOrAdd(name: "Server", value: "LocalLLM-Gateway")
        if !keepAlive { h.replaceOrAdd(name: "Connection", value: "close") }
        return h
    }

    func send(status: HTTPResponseStatus, headers: [(String, String)] = [], body: Data) async {
        guard !headSent else { return }
        headSent = true
        var h = baseHeaders(headers)
        h.replaceOrAdd(name: "Content-Length", value: String(body.count))
        if !h.contains(name: "Content-Type") { h.add(name: "Content-Type", value: "application/json") }
        let head = HTTPResponseHead(version: version, status: status, headers: h)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        if !body.isEmpty {
            channel.write(HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(bytes: body))), promise: nil)
        }
        try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        if !keepAlive { try? await channel.close().get() }
    }

    func sendJSON(_ status: HTTPResponseStatus, _ object: Any, headers: [(String, String)] = []) async {
        await send(status: status, headers: headers + [("Content-Type", "application/json")], body: JSON.data(object))
    }

    func startStream(status: HTTPResponseStatus, headers: [(String, String)]) async throws {
        headSent = true
        var h = baseHeaders(headers)
        h.remove(name: "Content-Length")
        h.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        h.replaceOrAdd(name: "Cache-Control", value: "no-cache")
        h.replaceOrAdd(name: "X-Accel-Buffering", value: "no")
        try await channel.writeAndFlush(HTTPServerResponsePart.head(HTTPResponseHead(version: version, status: status, headers: h))).get()
    }

    func write(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(bytes: bytes)))).get()
    }

    func finish() async {
        try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        if !keepAlive { try? await channel.close().get() }
    }

    func abort() { channel.close(promise: nil) }
}

private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let gateway: InferenceGateway
    private var head: HTTPRequestHead?
    private var body: ByteBuffer?
    private var tooLarge = false
    private var task: Task<Void, Never>?

    init(gateway: InferenceGateway) { self.gateway = gateway }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body = context.channel.allocator.buffer(capacity: 0)
            tooLarge = false
        case .body(var chunk):
            if (body?.readableBytes ?? 0) + chunk.readableBytes > gateway.maxBodyBytes { tooLarge = true; return }
            body?.writeBuffer(&chunk)
        case .end:
            guard let h = head else { return }
            head = nil
            let bytes = body.map { Data($0.readableBytesView) } ?? Data()
            body = nil
            let req = GatewayRequest(method: h.method, uri: h.uri, headers: h.headers, body: bytes)
            let writer = ResponseWriter(channel: context.channel, keepAlive: h.isKeepAlive, version: h.version)
            let gw = gateway
            let large = tooLarge
            task = Task {
                if large {
                    await writer.sendJSON(.payloadTooLarge, ["error": "request body too large"])
                } else {
                    await gw.handle(req, writer)
                }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Client went away: cancel the upstream generation so Ollama frees the slot.
        task?.cancel()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - Gateway

final class InferenceGateway {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: max(2, System.coreCount))
    private var serverChannel: Channel?
    private let children = Locked<[ObjectIdentifier: Channel]>([:])
    private let activeRequests = Locked<Int>(0)
    private let upstream: URLSession
    private unowned let app: AppCoordinator

    var maxBodyBytes: Int { app.config.current.gateway.maxRequestBodyMB * 1_048_576 }
    var inFlight: Int { activeRequests.get() }
    private(set) var boundPort: Int = 0

    init(app: AppCoordinator) {
        self.app = app
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3600
        c.timeoutIntervalForResource = 24 * 3600
        c.httpMaximumConnectionsPerHost = 128
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpShouldUsePipelining = false
        upstream = URLSession(configuration: c)
    }

    /// Binds with SO_REUSEPORT so a freshly built instance can bind the same port while
    /// the old one drains (local blue/green hand-off).
    func start(host: String, port: Int) throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 512)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .serverChannelOption(ChannelOptions.Types.SocketOption(level: SOL_SOCKET, name: SO_REUSEPORT), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.eventLoop.makeSucceededVoidFuture() }
                let id = ObjectIdentifier(channel)
                self.children.mutate { $0[id] = channel }
                channel.closeFuture.whenComplete { [weak self] _ in self?.children.mutate { $0.removeValue(forKey: id) } }
                return channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: true, withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(HTTPHandler(gateway: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
        let ch = try bootstrap.bind(host: host, port: port).wait()
        serverChannel = ch
        boundPort = ch.localAddress?.port ?? port
        Log.info("gateway", "Listening on http://\(host):\(boundPort) (\(System.coreCount) event loops)")
    }

    /// Graceful drain: stop accepting, wait for in-flight requests, then close idle keep-alive sockets.
    func drain(timeout: TimeInterval) async {
        try? await serverChannel?.close().get()
        Log.info("gateway", "Listener closed; draining \(inFlight) in-flight request(s)")
        let deadline = Date().addingTimeInterval(timeout)
        while inFlight > 0 && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        for ch in children.get().values { ch.close(promise: nil) }
    }

    // MARK: Routing

    func handle(_ req: GatewayRequest, _ w: ResponseWriter) async {
        activeRequests.mutate { $0 += 1 }
        defer { activeRequests.mutate { $0 -= 1 } }

        if let origin = req.headers.first(name: "Origin"), !originAllowed(origin) {
            await w.sendJSON(.forbidden, ["error": "origin \(origin) not allowed (gateway.allowedOrigins)"])
            return
        }
        let cors = corsHeaders(req)
        if req.method == .OPTIONS {
            // Echo the requested headers: browser SDKs (openai-js, ai-sdk) add their own x-* headers.
            let requested = req.headers.first(name: "Access-Control-Request-Headers")
            let allowHeaders = (requested?.isEmpty == false) ? requested! : "Authorization, Content-Type, X-Client-App, X-Priority"
            await w.send(status: .noContent, headers: cors + [
                ("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS"),
                ("Access-Control-Allow-Headers", allowHeaders),
                ("Access-Control-Max-Age", "86400")], body: Data())
            return
        }

        switch (req.method, req.path) {
        case (.GET, "/"), (.GET, "/health"), (.HEAD, "/health"):
            await w.sendJSON(.ok, app.healthPayload(), headers: cors)
        case (.GET, "/v1/hardware-profile"):
            await w.sendJSON(.ok, app.hardwareProfilePayload(), headers: cors)
        case (.GET, "/v1/metrics"):
            await w.sendJSON(.ok, app.metricsPayload(window: req.query["window"]), headers: cors)
        case (.POST, "/v1/system/git-sync"):
            let report = await app.updater.syncNow(trigger: .api, waitForBuild: false)
            await w.sendJSON(report.outcome == "rebuilding" ? .accepted : .ok, JSON.dictionary(report), headers: cors)
        case (.GET, "/v1/system/git-status"):
            await w.sendJSON(.ok, JSON.dictionary(app.updater.status), headers: cors)
        case (.POST, "/v1/system/reload-config"):
            let result = await app.reloadConfig(reason: "api")
            await w.sendJSON(result.ok ? .ok : .unprocessableEntity, ["ok": result.ok, "detail": result.detail], headers: cors)
        case (.POST, let p) where EndpointKind(rawValue: p) != nil:
            await inference(req, w, kind: EndpointKind(rawValue: p)!, cors: cors)
        default:
            await passthrough(req, w, cors: cors)
        }
    }

    private func originAllowed(_ origin: String) -> Bool {
        let allowed = app.config.current.gateway.allowedOrigins
        if allowed.contains("*") { return true }
        return allowed.contains { origin == $0 || origin.hasPrefix($0 + ":") || ($0.hasSuffix("://") && origin.hasPrefix($0)) }
    }

    private func corsHeaders(_ req: GatewayRequest) -> [(String, String)] {
        guard let origin = req.headers.first(name: "Origin") else { return [] }
        return [("Access-Control-Allow-Origin", origin), ("Vary", "Origin"),
                ("Access-Control-Expose-Headers", "X-LocalLLM-Model, X-LocalLLM-Queue-Ms, Retry-After")]
    }

    static func clientApp(_ headers: HTTPHeaders) -> String {
        if let c = headers.first(name: "X-Client-App"), !c.isEmpty { return String(c.prefix(64)) }
        if let ua = headers.first(name: "User-Agent"), !ua.isEmpty {
            let product = ua.split(separator: " ").first.map(String.init) ?? ua
            return String((product.split(separator: "/").first.map(String.init) ?? product).prefix(64))
        }
        return "unknown"
    }

    // MARK: Inference (tracked)

    private func inference(_ req: GatewayRequest, _ w: ResponseWriter, kind: EndpointKind, cors: [(String, String)]) async {
        let start = monotonicMs()
        let client = InferenceGateway.clientApp(req.headers)
        let cfg = app.config.current
        let plan = app.plan

        guard var json = JSON.object(req.body) else {
            await sendError(w, kind, .badRequest, "invalid JSON body", cors)
            return
        }
        let requested = json["model"] as? String
        let model = app.resolveModel(requested)
        json["model"] = model
        let stream = (json["stream"] as? Bool) ?? kind.defaultStream

        var clientWantsUsage = false
        if kind.isOpenAI {
            if stream {
                var so = json["stream_options"] as? [String: Any] ?? [:]
                clientWantsUsage = so["include_usage"] as? Bool ?? false
                so["include_usage"] = true    // exact engine token counts on the final SSE chunk
                json["stream_options"] = so
            }
        } else {
            var opts = json["options"] as? [String: Any] ?? [:]
            if opts["num_ctx"] == nil { opts["num_ctx"] = plan.numCtx }
            if opts["num_gpu"] == nil { opts["num_gpu"] = plan.numGPU }
            json["options"] = opts
            if json["keep_alive"] == nil { json["keep_alive"] = cfg.ollama.keepAlive }
        }

        let priorityHeader = req.headers.first(name: "X-Priority") ?? cfg.routing.clientPriorities[client]
        let priority = RequestPriority(header: priorityHeader)
        var record = RequestRecord(clientApp: client, endpoint: kind.rawValue, model: model, stream: stream, priority: priority.description)

        // 1) Memory guard circuit breaker
        if app.memory.isBreakerOpen {
            let retry = app.memory.retryAfterSeconds
            record.status = 429; record.error = "memory circuit breaker open"; record.totalMs = monotonicMs() - start
            app.tracker.record(record)
            await sendError(w, kind, .tooManyRequests, "memory pressure: available RAM below safety threshold; retry later",
                            cors + [("Retry-After", String(retry))])
            return
        }

        // 2) Priority admission (capacity = OLLAMA_NUM_PARALLEL)
        do {
            try await app.admission.acquire(priority: priority, timeout: cfg.gateway.queueTimeoutSeconds)
        } catch {
            let (status, msg): (HTTPResponseStatus, String)
            switch error as? AdmissionError {
            case .queueFull: (status, msg) = (.tooManyRequests, "gateway queue full")
            case .timeout: (status, msg) = (.serviceUnavailable, "timed out waiting for a free inference slot")
            default: return // client disconnected
            }
            record.status = Int(status.code); record.error = msg; record.totalMs = monotonicMs() - start
            app.tracker.record(record)
            await sendError(w, kind, status, msg, cors + [("Retry-After", "2")])
            return
        }
        defer { app.admission.release() }
        record.queueMs = monotonicMs() - start

        // 3) Upstream call
        var up = URLRequest(url: app.ollama.baseURL.appendingPathComponent(String(kind.rawValue.dropFirst())))
        up.httpMethod = "POST"
        up.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = req.headers.first(name: "Authorization") { up.setValue(auth, forHTTPHeaderField: "Authorization") }
        up.httpBody = try? JSONSerialization.data(withJSONObject: json)
        var usage = UsageExtractor(kind: kind, startMs: start)
        let extra = cors + [("X-LocalLLM-Model", model), ("X-LocalLLM-Queue-Ms", String(format: "%.1f", record.queueMs))]

        do {
            if !stream {
                let (data, resp) = try await upstream.data(for: up)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
                record.status = status
                if let obj = JSON.object(data) {
                    if kind.isOpenAI { usage.absorbOpenAINonStream(obj) } else { usage.absorbNative(obj) }
                    if status >= 400 { record.error = "\(obj["error"] ?? "upstream error")" }
                }
                usage.fill(&record, endMs: monotonicMs(), streamed: false)
                await w.send(status: HTTPResponseStatus(statusCode: status), headers: extra + [("Content-Type", contentType(resp))], body: data)
            } else {
                let (bytes, resp) = try await upstream.bytes(for: up)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
                record.status = status
                try await w.startStream(status: HTTPResponseStatus(statusCode: status), headers: extra + [("Content-Type", contentType(resp))])
                var line: [UInt8] = []
                line.reserveCapacity(2048)
                var dropNextBlank = false
                for try await byte in bytes {
                    line.append(byte)
                    guard byte == 0x0A else { continue }
                    let isBlank = line.count <= 2 && (line.first == 0x0A || line.first == 0x0D)
                    if isBlank && dropNextBlank {
                        dropNextBlank = false
                    } else if usage.consume(line: line, now: monotonicMs(), clientWantsUsage: clientWantsUsage) {
                        dropNextBlank = true // swallow the usage-only event we injected
                    } else {
                        try await w.write(line)
                    }
                    line.removeAll(keepingCapacity: true)
                }
                if !line.isEmpty {
                    _ = usage.consume(line: line, now: monotonicMs(), clientWantsUsage: clientWantsUsage)
                    try await w.write(line)
                }
                usage.fill(&record, endMs: monotonicMs(), streamed: true)
                await w.finish()
            }
        } catch {
            let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled || !w.isActive
            usage.fill(&record, endMs: monotonicMs(), streamed: stream)
            record.status = cancelled ? 499 : 502
            record.error = cancelled ? "client disconnected" : "upstream: \(error.localizedDescription)"
            if !w.headSent && !cancelled {
                await sendError(w, kind, .badGateway, "inference engine unavailable: \(error.localizedDescription)", cors)
            } else if w.headSent { w.abort() }
        }
        app.tracker.record(record)
    }

    private func contentType(_ resp: URLResponse) -> String {
        (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
    }

    private func sendError(_ w: ResponseWriter, _ kind: EndpointKind?, _ status: HTTPResponseStatus, _ message: String, _ headers: [(String, String)]) async {
        let body: [String: Any]
        if kind?.isOpenAI ?? false {
            let type = status == .tooManyRequests ? "rate_limit_error" : (status.code >= 500 ? "server_error" : "invalid_request_error")
            body = ["error": ["message": message, "type": type, "code": Int(status.code)]]
        } else {
            body = ["error": message]
        }
        await w.sendJSON(status, body, headers: headers)
    }

    // MARK: Pass-through proxy (tags, show, ps, embeddings, models, pull, ...)

    private func passthrough(_ req: GatewayRequest, _ w: ResponseWriter, cors: [(String, String)]) async {
        guard var comps = URLComponents(url: app.ollama.baseURL, resolvingAgainstBaseURL: false) else { return }
        let parts = req.uri.split(separator: "?", maxSplits: 1)
        comps.path = String(parts.first ?? "/")
        comps.percentEncodedQuery = parts.count > 1 ? String(parts[1]) : nil
        guard let url = comps.url else { await sendError(w, nil, .badRequest, "bad uri", cors); return }
        var up = URLRequest(url: url)
        up.httpMethod = req.method.rawValue
        for (name, value) in req.headers where !["host", "connection", "content-length", "origin", "transfer-encoding", "accept-encoding"].contains(name.lowercased()) {
            up.addValue(value, forHTTPHeaderField: name)
        }
        if !req.body.isEmpty {
            var body = req.body
            // Route aliases also for embeddings/show requests.
            if var obj = JSON.object(req.body), let m = obj["model"] as? String {
                obj["model"] = app.resolveModel(m)
                body = (try? JSONSerialization.data(withJSONObject: obj)) ?? req.body
            }
            up.httpBody = body
        }
        do {
            let (bytes, resp) = try await upstream.bytes(for: up)
            let http = resp as? HTTPURLResponse
            try await w.startStream(status: HTTPResponseStatus(statusCode: http?.statusCode ?? 502),
                                    headers: cors + [("Content-Type", contentType(resp))])
            var buffer: [UInt8] = []
            buffer.reserveCapacity(16_384)
            for try await byte in bytes {
                buffer.append(byte)
                if byte == 0x0A || buffer.count >= 65_536 {
                    try await w.write(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try await w.write(buffer)
            await w.finish()
        } catch {
            if !w.headSent { await sendError(w, nil, .badGateway, "engine unavailable: \(error.localizedDescription)", cors) } else { w.abort() }
        }
    }
}
