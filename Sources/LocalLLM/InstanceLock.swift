import Foundation

/// Single-instance guard: an exclusive `flock` on Application Support/LocalLLM/instance.lock.
///
/// Every copy of the app (/Applications, dist/, the auto-updated binary in bin/) shares the same
/// Application Support folder, so only one can own the gateway and Ollama. A second launch exits
/// right away instead of fighting the running one over Ollama.
///
/// - The descriptor is O_CLOEXEC: the lock is released on `execv` (Launcher redirect) and never
///   leaks into child processes such as Ollama, which may outlive us after a hand-off.
/// - The blue/green successor (LOCALLLM_TAKEOVER=1) starts while its parent still holds the lock,
///   so it waits for it in the background and takes it once the parent drains and exits.
enum InstanceLock {
    private static var fd: Int32 = -1

    static var url: URL { AppPaths.appSupport.appendingPathComponent("instance.lock") }

    static func acquireOrExit() {
        let env = ProcessInfo.processInfo.environment
        guard env["LOCALLLM_ALLOW_MULTIPLE"] != "1" else { return }
        fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            Log.warn("instance", "Cannot open \(url.path) (errno \(errno)); running without single-instance lock")
            return
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            recordOwner()
            return
        }
        if env["LOCALLLM_TAKEOVER"] == "1" {
            Log.info("instance", "Hand-off: waiting for previous instance to release the lock")
            Thread.detachNewThread {
                while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
                recordOwner()
                Log.info("instance", "Lock acquired after hand-off")
            }
            return
        }
        let owner = ownerPid().map { "pid \($0)" } ?? "unknown pid"
        Log.info("instance", "LocalLLM is already running (\(owner)); this copy exits")
        Log.flush()
        exit(0)
    }

    private static func recordOwner() {
        let s = "\(getpid())\n"
        ftruncate(fd, 0)
        _ = s.withCString { pwrite(fd, $0, strlen($0), 0) }
    }

    private static func ownerPid() -> Int32? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
