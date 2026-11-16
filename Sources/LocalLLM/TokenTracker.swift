import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct RequestRecord {
    var timestamp = Date()
    var clientApp: String
    var endpoint: String
    var model: String
    var stream: Bool
    var priority: String
    var status: Int = 0
    var promptTokens: Int?
    var completionTokens: Int?
    var promptEvalMs: Double?
    var evalMs: Double?
    var loadMs: Double?
    var ttftMs: Double?
    var queueMs: Double = 0
    var totalMs: Double = 0
    var tokensPerSec: Double?
    var timingSource = "gateway"
    var error: String?
}

struct LiveTokenStats: Codable {
    var requests: Int = 0
    var errors: Int = 0
    var rejected: Int = 0
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var lastTokensPerSec: Double?
    var lastTtftMs: Double?
    var lastModel: String?
    var lastClient: String?
}

// MARK: - Minimal SQLite wrapper

final class SQLiteDB {
    private(set) var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
                             : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close_v2(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw NSError(domain: "sqlite", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: 3, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
        return stmt
    }

    static func bind(_ stmt: OpaquePointer?, _ values: [Any?]) {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(stmt, idx)
            case let x as Int: sqlite3_bind_int64(stmt, idx, Int64(x))
            case let x as Int64: sqlite3_bind_int64(stmt, idx, x)
            case let x as Double: sqlite3_bind_double(stmt, idx, x)
            case let x as Bool: sqlite3_bind_int(stmt, idx, x ? 1 : 0)
            case let x as String: sqlite3_bind_text(stmt, idx, x, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_text(stmt, idx, "\(v!)", -1, SQLITE_TRANSIENT)
            }
        }
    }

    /// Runs a query returning rows as dictionaries (JSONSerialization-friendly).
    func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        SQLiteDB.bind(stmt, params)
        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = (sqlite3_column_double(stmt, c) * 100).rounded() / 100
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, c))
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        return rows
    }
}

// MARK: - Tracker

/// Persists every inference request in SQLite (WAL). The request path never blocks on disk:
/// records are enqueued to a serial writer queue; readers use a separate connection, which
/// WAL allows concurrently with the writer.
final class TokenTracker {
    private let writeQueue = DispatchQueue(label: "localllm.sqlite.writer", qos: .utility)
    private let readQueue = DispatchQueue(label: "localllm.sqlite.reader", qos: .userInitiated)
    private var writer: SQLiteDB?
    private var reader: SQLiteDB?
    private var insertStmt: OpaquePointer?
    private let live = Locked(LiveTokenStats())
    private let allTime = Locked(LiveTokenStats())

    init(path: URL = AppPaths.database, readOnly: Bool = false) {
        do {
            if !readOnly {
                let w = try SQLiteDB(path: path.path)
                try w.exec("""
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=NORMAL;
                PRAGMA wal_autocheckpoint=1000;
                CREATE TABLE IF NOT EXISTS requests(
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  ts REAL NOT NULL,
                  client_app TEXT NOT NULL,
                  endpoint TEXT NOT NULL,
                  model TEXT NOT NULL,
                  stream INTEGER NOT NULL,
                  priority TEXT NOT NULL,
                  status INTEGER NOT NULL,
                  prompt_tokens INTEGER,
                  completion_tokens INTEGER,
                  prompt_eval_ms REAL,
                  eval_ms REAL,
                  load_ms REAL,
                  ttft_ms REAL,
                  queue_ms REAL,
                  total_ms REAL,
                  tokens_per_sec REAL,
                  timing_source TEXT,
                  error TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_requests_ts ON requests(ts);
                CREATE INDEX IF NOT EXISTS idx_requests_client ON requests(client_app, ts);
                CREATE INDEX IF NOT EXISTS idx_requests_model ON requests(model, ts);
                CREATE TABLE IF NOT EXISTS incidents(
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  ts REAL NOT NULL,
                  kind TEXT NOT NULL,
                  detail TEXT NOT NULL
                );
                """)
                insertStmt = try w.prepare("""
                INSERT INTO requests(ts, client_app, endpoint, model, stream, priority, status, prompt_tokens, completion_tokens,
                  prompt_eval_ms, eval_ms, load_ms, ttft_ms, queue_ms, total_ms, tokens_per_sec, timing_source, error)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
                writer = w
            }
            reader = try SQLiteDB(path: path.path, readOnly: readOnly)
            if let totals = reader?.query("SELECT COUNT(*) AS n, COALESCE(SUM(prompt_tokens),0) AS p, COALESCE(SUM(completion_tokens),0) AS c FROM requests").first {
                allTime.mutate {
                    $0.requests = totals["n"] as? Int ?? 0
                    $0.promptTokens = totals["p"] as? Int ?? 0
                    $0.completionTokens = totals["c"] as? Int ?? 0
                }
            }
        } catch {
            Log.error("tokens", "SQLite init failed: \(error.localizedDescription)")
        }
    }

    var liveStats: LiveTokenStats { live.get() }
    var allTimeStats: LiveTokenStats { allTime.get() }

    func record(_ r: RequestRecord) {
        let ok = (200..<300).contains(r.status)
        let update: (inout LiveTokenStats) -> Void = { s in
            s.requests += 1
            if r.status == 429 || r.status == 503 { s.rejected += 1 } else if !ok { s.errors += 1 }
            s.promptTokens += r.promptTokens ?? 0
            s.completionTokens += r.completionTokens ?? 0
            if ok, let tps = r.tokensPerSec { s.lastTokensPerSec = tps }
            if ok, let t = r.ttftMs { s.lastTtftMs = t }
            s.lastModel = r.model
            s.lastClient = r.clientApp
        }
        live.mutate(update)
        allTime.mutate(update)

        writeQueue.async { [weak self] in
            guard let self, let stmt = self.insertStmt else { return }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            SQLiteDB.bind(stmt, [
                r.timestamp.timeIntervalSince1970, r.clientApp, r.endpoint, r.model, r.stream, r.priority, r.status,
                r.promptTokens, r.completionTokens, r.promptEvalMs, r.evalMs, r.loadMs, r.ttftMs, r.queueMs,
                r.totalMs, r.tokensPerSec, r.timingSource, r.error
            ])
            if sqlite3_step(stmt) != SQLITE_DONE, let h = self.writer?.handle {
                Log.error("tokens", "insert failed: \(String(cString: sqlite3_errmsg(h)))")
            }
        }
    }

    func incident(_ kind: String, _ detail: String) {
        Log.warn("incident", "\(kind): \(detail)")
        writeQueue.async { [weak self] in
            guard let w = self?.writer, let stmt = try? w.prepare("INSERT INTO incidents(ts, kind, detail) VALUES(?,?,?)") else { return }
            defer { sqlite3_finalize(stmt) }
            SQLiteDB.bind(stmt, [Date().timeIntervalSince1970, kind, detail])
            sqlite3_step(stmt)
        }
    }

    /// Aggregated metrics for GET /v1/metrics.
    func metrics(since: Date?) -> [String: Any] {
        readQueue.sync {
            guard let db = reader else { return ["error": "database unavailable"] }
            let sinceTs = since?.timeIntervalSince1970 ?? 0
            let agg = """
                COUNT(*) AS requests,
                SUM(CASE WHEN status BETWEEN 200 AND 299 THEN 1 ELSE 0 END) AS ok,
                SUM(CASE WHEN status IN (429,503) THEN 1 ELSE 0 END) AS rejected,
                SUM(CASE WHEN status >= 400 AND status NOT IN (429,503) THEN 1 ELSE 0 END) AS errors,
                COALESCE(SUM(prompt_tokens),0) AS prompt_tokens,
                COALESCE(SUM(completion_tokens),0) AS completion_tokens,
                COALESCE(SUM(prompt_tokens),0) + COALESCE(SUM(completion_tokens),0) AS total_tokens,
                AVG(tokens_per_sec) AS avg_tokens_per_sec,
                MAX(tokens_per_sec) AS max_tokens_per_sec,
                AVG(ttft_ms) AS avg_ttft_ms,
                AVG(queue_ms) AS avg_queue_ms,
                AVG(total_ms) AS avg_total_ms
            """
            let totals = db.query("SELECT \(agg) FROM requests WHERE ts >= ?", [sinceTs]).first ?? [:]
            let byClient = db.query("SELECT client_app, \(agg) FROM requests WHERE ts >= ? GROUP BY client_app ORDER BY total_tokens DESC", [sinceTs])
            let byModel = db.query("SELECT model, \(agg) FROM requests WHERE ts >= ? GROUP BY model ORDER BY total_tokens DESC", [sinceTs])
            let byEndpoint = db.query("SELECT endpoint, \(agg) FROM requests WHERE ts >= ? GROUP BY endpoint ORDER BY requests DESC", [sinceTs])
            let ttftP = percentiles(db, column: "ttft_ms", since: sinceTs)
            let tpsP = percentiles(db, column: "tokens_per_sec", since: sinceTs)
            let recent = db.query("""
                SELECT datetime(ts,'unixepoch','localtime') AS time, client_app, endpoint, model, stream, priority, status,
                       prompt_tokens, completion_tokens, ttft_ms, tokens_per_sec, prompt_eval_ms, eval_ms, queue_ms, total_ms,
                       timing_source, error
                FROM requests ORDER BY id DESC LIMIT 25
                """)
            let incidents = db.query("SELECT datetime(ts,'unixepoch','localtime') AS time, kind, detail FROM incidents ORDER BY id DESC LIMIT 20")
            var t = totals
            t["ttft_ms_p50"] = ttftP.0 ?? NSNull(); t["ttft_ms_p95"] = ttftP.1 ?? NSNull()
            t["tokens_per_sec_p50"] = tpsP.0 ?? NSNull(); t["tokens_per_sec_p95"] = tpsP.1 ?? NSNull()
            return ["totals": t, "byClient": byClient, "byModel": byModel, "byEndpoint": byEndpoint,
                    "recent": recent, "incidents": incidents]
        }
    }

    private func percentiles(_ db: SQLiteDB, column: String, since: Double) -> (Double?, Double?) {
        let n = db.query("SELECT COUNT(\(column)) AS n FROM requests WHERE ts >= ? AND \(column) IS NOT NULL", [since]).first?["n"] as? Int ?? 0
        guard n > 0 else { return (nil, nil) }
        func at(_ q: Double) -> Double? {
            let offset = min(n - 1, Int(Double(n - 1) * q))
            return db.query("SELECT \(column) AS v FROM requests WHERE ts >= ? AND \(column) IS NOT NULL ORDER BY \(column) LIMIT 1 OFFSET ?", [since, offset]).first?["v"] as? Double
        }
        return (at(0.5), at(0.95))
    }
}

// MARK: - Usage extraction from engine responses (stream and non-stream)

enum EndpointKind: String {
    case openAIChat = "/v1/chat/completions"
    case openAICompletions = "/v1/completions"
    case ollamaChat = "/api/chat"
    case ollamaGenerate = "/api/generate"

    var isOpenAI: Bool { self == .openAIChat || self == .openAICompletions }
    /// Ollama native endpoints stream by default; OpenAI-compatible ones do not.
    var defaultStream: Bool { !isOpenAI }
}

/// Incrementally consumes stream lines (NDJSON or SSE) and extracts exact engine counters.
struct UsageExtractor {
    let kind: EndpointKind
    let startMs: Double
    var firstTokenMs: Double?
    var lastTokenMs: Double?
    var promptTokens: Int?
    var completionTokens: Int?
    var promptEvalNs: Double?
    var evalNs: Double?
    var loadNs: Double?
    var sawEngineTiming = false
    var streamError: String?

    init(kind: EndpointKind, startMs: Double) { self.kind = kind; self.startMs = startMs }

    /// Returns true if the line is a usage-only SSE event the client did not ask for (to be dropped).
    mutating func consume(line: [UInt8], now: Double, clientWantsUsage: Bool) -> Bool {
        guard line.count > 2 else { return false }
        if kind.isOpenAI {
            guard line.starts(with: Array("data: ".utf8)) else { return false }
            let payload = line.dropFirst(6)
            if payload.starts(with: Array("[DONE]".utf8)) { return false }
            if contains(payload, "\"usage\"") || contains(payload, "\"error\""),
               let obj = JSON.object(Data(payload)) {
                if let usage = obj["usage"] as? [String: Any] {
                    promptTokens = JSON.int(usage["prompt_tokens"])
                    completionTokens = JSON.int(usage["completion_tokens"])
                }
                if let err = obj["error"] { streamError = "\(err)" }
                let choices = obj["choices"] as? [Any] ?? []
                if choices.isEmpty && obj["usage"] != nil {
                    return !clientWantsUsage
                }
            }
            markToken(now)
            return false
        } else {
            if contains(line[...], "\"done\":true") || contains(line[...], "\"error\""), let obj = JSON.object(Data(line)) {
                absorbNative(obj)
                if obj["done"] as? Bool == true { return false }
            }
            markToken(now)
            return false
        }
    }

    private mutating func markToken(_ now: Double) {
        if firstTokenMs == nil { firstTokenMs = now }
        lastTokenMs = now
    }

    mutating func absorbNative(_ obj: [String: Any]) {
        if let e = obj["error"] { streamError = "\(e)" }
        if let v = JSON.int(obj["prompt_eval_count"]) { promptTokens = v }
        if let v = JSON.int(obj["eval_count"]) { completionTokens = v }
        if let v = JSON.double(obj["prompt_eval_duration"]) { promptEvalNs = v; sawEngineTiming = true }
        if let v = JSON.double(obj["eval_duration"]) { evalNs = v; sawEngineTiming = true }
        if let v = JSON.double(obj["load_duration"]) { loadNs = v }
    }

    mutating func absorbOpenAINonStream(_ obj: [String: Any]) {
        if let usage = obj["usage"] as? [String: Any] {
            promptTokens = JSON.int(usage["prompt_tokens"])
            completionTokens = JSON.int(usage["completion_tokens"])
        }
    }

    func fill(_ r: inout RequestRecord, endMs: Double, streamed: Bool) {
        r.promptTokens = promptTokens
        r.completionTokens = completionTokens
        r.totalMs = endMs - startMs
        if sawEngineTiming {
            r.timingSource = "engine"
            r.promptEvalMs = promptEvalNs.map { $0 / 1e6 }
            r.evalMs = evalNs.map { $0 / 1e6 }
            r.loadMs = loadNs.map { $0 / 1e6 }
            if let c = completionTokens, let e = evalNs, e > 0 { r.tokensPerSec = Double(c) / (e / 1e9) }
        } else if let first = firstTokenMs, let last = lastTokenMs, last > first, let c = completionTokens, c > 1 {
            r.evalMs = last - first
            r.tokensPerSec = Double(c - 1) / ((last - first) / 1000)
        }
        if streamed, let first = firstTokenMs {
            r.ttftMs = first - startMs
        } else if sawEngineTiming {
            r.ttftMs = ((loadNs ?? 0) + (promptEvalNs ?? 0)) / 1e6
        }
        if let e = streamError { r.error = e }
    }

    private func contains<C: Collection>(_ haystack: C, _ needle: String) -> Bool where C.Element == UInt8 {
        Data(haystack).range(of: Data(needle.utf8)) != nil
    }
}
