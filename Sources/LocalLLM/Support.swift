import Foundation
import os

// MARK: - Locking

final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    @discardableResult
    func mutate<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}

// MARK: - Units

let GiB: Double = 1_073_741_824
func gib(_ bytes: UInt64) -> Double { Double(bytes) / GiB }
func bytes(fromGiB value: Double) -> UInt64 { UInt64(max(0, value) * GiB) }
func monotonicMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

// MARK: - Run mode / environment

enum RunMode: Equatable {
    case app          // SwiftUI menu bar app
    case headless     // gateway + ollama + updater, no UI (servers, CI, debugging)
    case healthCheck(port: Int) // candidate binary self-test used by the updater
}

enum AppEnvironment {
    static let env = ProcessInfo.processInfo.environment

    /// The .app bundle that installed us. When an updated binary is running from
    /// Application Support the launcher passes the bundle path through the environment.
    static let appBundleURL: URL? = {
        if let p = env["LOCALLLM_APP_BUNDLE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }()

    static let appBundleInfo: [String: Any] = {
        if let url = appBundleURL, let b = Bundle(url: url), let info = b.infoDictionary { return info }
        return Bundle.main.infoDictionary ?? [:]
    }()

    static let resourcesURL: URL? = {
        if let p = env["LOCALLLM_RESOURCES"], !p.isEmpty { return URL(fileURLWithPath: p) }
        if let bundle = appBundleURL { return bundle.appendingPathComponent("Contents/Resources") }
        return nil
    }()

    /// Commit the installed .app was built from (written by build_dmg.sh into Info.plist).
    static var bundledCommit: String { appBundleInfo["LLMLXCommit"] as? String ?? "dev" }
    /// Commit of the binary that is actually running (differs after a Git auto-update).
    static var runningCommit: String { env["LOCALLLM_COMMIT"] ?? bundledCommit }
    static var bundledRemote: String? { appBundleInfo["LLMLXRemote"] as? String }
    static var bundledBranch: String? { appBundleInfo["LLMLXBranch"] as? String }
    /// Version of the running binary. Auto-updated binaries receive LOCALLLM_VERSION from the updater
    /// (1.0.<commit count>, the same scheme build_dmg.sh writes into Info.plist).
    static var version: String {
        if let v = env["LOCALLLM_VERSION"], !v.isEmpty { return v }
        return appBundleInfo["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    }
    static var shortCommit: String { String(runningCommit.prefix(7)) }
    static var displayVersion: String { "v\(version) (\(shortCommit))" }
    static var executableURL: URL { URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath() }
}

enum AppPaths {
    static let fm = FileManager.default

    static let appSupport: URL = {
        let base = env("LOCALLLM_HOME").map { URL(fileURLWithPath: $0) }
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalLLM", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static let logs: URL = {
        let u = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/LocalLLM", isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static var repo: URL { appSupport.appendingPathComponent("repo", isDirectory: true) }
    static var buildScratch: URL { appSupport.appendingPathComponent("build", isDirectory: true) }
    static var binDir: URL {
        let u = appSupport.appendingPathComponent("bin", isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var currentBinaryLink: URL { binDir.appendingPathComponent("current") }
    static var currentBinaryMeta: URL { binDir.appendingPathComponent("current.json") }
    static var database: URL { appSupport.appendingPathComponent("telemetry.sqlite") }
    static var ollamaPidFile: URL { appSupport.appendingPathComponent("ollama.pid.json") }
    static var updaterState: URL { appSupport.appendingPathComponent("updater-state.json") }
    static var modelOverride: URL { appSupport.appendingPathComponent("model-override.json") }

    /// Dashboard static files: Git-synced repo first (updates without recompiling), then the app bundle.
    static var webRoot: URL? {
        var candidates: [URL] = []
        if let e = ProcessInfo.processInfo.environment["LOCALLLM_WEB_ROOT"], !e.isEmpty { candidates.append(URL(fileURLWithPath: e)) }
        candidates.append(repo.appendingPathComponent("web/dist"))
        if let r = AppEnvironment.resourcesURL { candidates.append(r.appendingPathComponent("web")) }
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }

    private static func env(_ k: String) -> String? {
        let v = ProcessInfo.processInfo.environment[k]
        return (v?.isEmpty ?? true) ? nil : v
    }
}

// MARK: - Logging

enum Log {
    private static let subsystem = "com.llmlx.localllm"
    private static let queue = DispatchQueue(label: "localllm.filelog", qos: .utility)
    private static let fileURL = AppPaths.logs.appendingPathComponent("localllm.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ category: String, _ message: String) { write(.info, category, message) }
    static func warn(_ category: String, _ message: String) { write(.default, category, "WARN " + message) }
    static func error(_ category: String, _ message: String) { write(.error, category, "ERROR " + message) }
    /// Waits for pending file writes (use before `exit`).
    static func flush() { queue.sync {} }

    private static func write(_ type: OSLogType, _ category: String, _ message: String) {
        Logger(subsystem: subsystem, category: category).log(level: type, "\(message, privacy: .public)")
        let line = "\(formatter.string(from: Date())) [\(getpid())] [\(category)] \(message)\n"
        if ProcessInfo.processInfo.environment["LOCALLLM_LOG_STDERR"] == "1" {
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: fileURL) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}

// MARK: - Process runner (deadlock-free: output goes to temp files, not pipes)

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    var ok: Bool { status == 0 && !timedOut }
    var combined: String { (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum ProcessRunner {
    static func run(_ executable: String,
                    _ arguments: [String],
                    cwd: URL? = nil,
                    environment: [String: String] = [:],
                    timeout: TimeInterval = 120,
                    qos: QualityOfService = .utility,
                    appendLogTo logURL: URL? = nil) async -> ProcessResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ProcessResult, Never>) in
            DispatchQueue.global(qos: qos == .background ? .background : .utility).async {
                cont.resume(returning: runSync(executable, arguments, cwd: cwd, environment: environment,
                                               timeout: timeout, qos: qos, appendLogTo: logURL))
            }
        }
    }

    static func runSync(_ executable: String, _ arguments: [String], cwd: URL? = nil,
                        environment: [String: String] = [:], timeout: TimeInterval = 120,
                        qos: QualityOfService = .utility, appendLogTo logURL: URL? = nil) -> ProcessResult {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let outURL = tmp.appendingPathComponent("localllm-\(UUID().uuidString).out")
        let errURL = tmp.appendingPathComponent("localllm-\(UUID().uuidString).err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer { try? fm.removeItem(at: outURL); try? fm.removeItem(at: errURL) }

        guard let outH = try? FileHandle(forWritingTo: outURL), let errH = try? FileHandle(forWritingTo: errURL) else {
            return ProcessResult(status: -1, stdout: "", stderr: "cannot create temp files", timedOut: false)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let cwd { p.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        p.environment = env
        p.qualityOfService = qos
        p.standardOutput = outH
        p.standardError = errH
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            return ProcessResult(status: -1, stdout: "", stderr: "launch failed: \(error.localizedDescription)", timedOut: false)
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                done.wait()
            }
        }
        try? outH.close(); try? errH.close()
        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        if let logURL {
            let text = "$ \(executable) \(arguments.joined(separator: " "))\n\(out)\n\(err)\nexit=\(p.terminationStatus) timedOut=\(timedOut)\n"
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close()
            } else { try? text.data(using: .utf8)?.write(to: logURL) }
        }
        return ProcessResult(status: p.terminationStatus, stdout: out, stderr: err, timedOut: timedOut)
    }
}

// MARK: - JSON helpers

enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Converts any Encodable into a JSONSerialization-compatible dictionary.
    static func dictionary<T: Encodable>(_ value: T) -> Any {
        guard let d = try? encoder.encode(value), let o = try? JSONSerialization.jsonObject(with: d) else { return NSNull() }
        return o
    }

    static func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    static func double(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let i = any as? Int { return Double(i) }
        return nil
    }
}
