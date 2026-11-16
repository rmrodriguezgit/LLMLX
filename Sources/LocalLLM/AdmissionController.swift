import Foundation

enum RequestPriority: Int, Comparable, CustomStringConvertible {
    case low = 0, normal = 1, high = 2

    static func < (a: RequestPriority, b: RequestPriority) -> Bool { a.rawValue < b.rawValue }
    var description: String { self == .high ? "high" : self == .low ? "low" : "normal" }

    init(header: String?) {
        switch header?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "high", "urgent", "interactive", "2", "3", "4", "5", "6", "7", "8", "9": self = .high
        case "low", "batch", "background", "0": self = .low
        default: self = .normal
        }
    }
}

enum AdmissionError: Error {
    case queueFull
    case timeout
    case cancelled
}

/// Priority admission queue in front of Ollama. Capacity == OLLAMA_NUM_PARALLEL so the
/// engine's parallel slots stay saturated while the gateway (not Ollama's FIFO) decides
/// who goes next: high > normal > low, FIFO within a class.
final class AdmissionController {
    private struct Waiter {
        let id: UInt64
        let priority: RequestPriority
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var capacity: Int
    private var maxQueue: Int
    private var inUse = 0
    private var paused = false
    private var waiters: [Waiter] = []
    private var nextId: UInt64 = 0

    /// Invoked (outside the lock) when the last in-flight request finishes.
    var onIdle: (() -> Void)?

    init(capacity: Int, maxQueue: Int) {
        self.capacity = max(1, capacity)
        self.maxQueue = maxQueue
    }

    var stats: (inFlight: Int, queued: Int, capacity: Int, paused: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (inUse, waiters.count, capacity, paused)
    }

    func configure(capacity: Int, maxQueue: Int) {
        lock.lock()
        self.capacity = max(1, capacity)
        self.maxQueue = maxQueue
        let resumed = dispatchLocked()
        lock.unlock()
        resumed.forEach { $0.resume() }
    }

    private enum FastPath { case admitted, full, wait(UInt64) }

    private func tryAdmit() -> FastPath {
        lock.lock(); defer { lock.unlock() }
        if !paused && inUse < capacity && waiters.isEmpty { inUse += 1; return .admitted }
        if waiters.count >= maxQueue { return .full }
        nextId += 1
        return .wait(nextId)
    }

    private func enqueue(_ id: UInt64, _ priority: RequestPriority, _ cont: CheckedContinuation<Void, Error>) {
        lock.lock()
        if Task.isCancelled {
            lock.unlock()
            cont.resume(throwing: AdmissionError.cancelled)
            return
        }
        waiters.append(Waiter(id: id, priority: priority, continuation: cont))
        // Stable order: higher priority first, FIFO (by id) within a class.
        waiters.sort { $0.priority != $1.priority ? $0.priority > $1.priority : $0.id < $1.id }
        let resumed = dispatchLocked()
        lock.unlock()
        resumed.forEach { $0.resume() }
    }

    func acquire(priority: RequestPriority, timeout: TimeInterval) async throws {
        let id: UInt64
        switch tryAdmit() {
        case .admitted: return
        case .full: throw AdmissionError.queueFull
        case .wait(let n): id = n
        }

        let timer = DispatchWorkItem { [weak self] in self?.cancelWaiter(id, error: AdmissionError.timeout) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.enqueue(id, priority, cont)
            }
        } onCancel: {
            self.cancelWaiter(id, error: AdmissionError.cancelled)
        }
    }

    func release() {
        lock.lock()
        inUse = max(0, inUse - 1)
        let resumed = dispatchLocked()
        let becameIdle = inUse == 0 && waiters.isEmpty
        lock.unlock()
        resumed.forEach { $0.resume() }
        if becameIdle { onIdle?() }
    }

    /// Stops dispatching queued work (new requests queue instead of failing). Used while the
    /// Ollama process restarts with a new hardware profile.
    func pause() { lock.lock(); paused = true; lock.unlock() }

    func resume() {
        lock.lock()
        paused = false
        let resumed = dispatchLocked()
        lock.unlock()
        resumed.forEach { $0.resume() }
    }

    /// Waits until no request is in flight (bounded by timeout).
    func waitForIdle(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while stats.inFlight > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func dispatchLocked() -> [CheckedContinuation<Void, Error>] {
        var out: [CheckedContinuation<Void, Error>] = []
        while !paused && inUse < capacity && !waiters.isEmpty {
            out.append(waiters.removeFirst().continuation)
            inUse += 1
        }
        return out
    }

    private func cancelWaiter(_ id: UInt64, error: Error) {
        lock.lock()
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        let w = waiters.remove(at: i)
        lock.unlock()
        w.continuation.resume(throwing: error)
    }
}
