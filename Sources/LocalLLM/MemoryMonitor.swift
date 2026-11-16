import Foundation
import Darwin

struct MemorySnapshot: Codable, Equatable {
    var timestamp: Date
    var totalBytes: UInt64
    /// Memory obtainable without swapping: free + speculative + purgeable + clean file cache.
    var availableBytes: UInt64
    var freeBytes: UInt64
    var activeBytes: UInt64
    var inactiveBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var purgeableBytes: UInt64
    var fileBackedBytes: UInt64
    var swapUsedBytes: UInt64
    var swapoutsTotal: UInt64
    var pressure: String
    var breakerOpen: Bool
    var thresholdBytes: UInt64
}

struct MemoryPoint: Codable {
    var t: Double              // unix seconds
    var available: UInt64
    var used: UInt64
    var swap: UInt64
    var breaker: Bool
}

/// Real-time Mach VM sampling + kernel memory-pressure events driving a circuit breaker.
final class MemoryMonitor {
    private static let host = mach_host_self()
    private static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(host, &size)
        return UInt64(size)
    }()

    private let queue = DispatchQueue(label: "localllm.memory", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private let snapshotBox = Locked<MemorySnapshot>(MemoryMonitor.readSnapshotRaw())
    private let thresholdBox = Locked<UInt64>(bytes(fromGiB: 1.8))
    private let breaker = Locked<Bool>(false)
    private var pressureLevel = "normal"
    private var healthySince: Double?
    private var config: MemoryGuardConfig
    private let historyBox = Locked<[MemoryPoint]>([])
    private var lastHistoryAt: Double = 0
    /// 2-second resolution, 15 minutes of history for the dashboard.
    private let historyInterval: Double = 2
    private let historyCapacity = 450

    /// Called on the monitor queue when the breaker opens (true) or closes (false).
    var onBreakerChange: ((Bool, MemorySnapshot) -> Void)?

    init(config: MemoryGuardConfig) { self.config = config }

    var snapshot: MemorySnapshot { snapshotBox.get() }
    var isBreakerOpen: Bool { breaker.get() }
    var retryAfterSeconds: Int { config.retryAfterSeconds }
    var history: [MemoryPoint] { historyBox.get() }

    func update(threshold: UInt64, config: MemoryGuardConfig) {
        thresholdBox.set(threshold)
        queue.async { self.config = config; self.restartTimer() }
    }

    func start() {
        queue.async {
            self.restartTimer()
            let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: self.queue)
            src.setEventHandler { [weak self] in
                guard let self else { return }
                let e = src.data
                self.pressureLevel = e.contains(.critical) ? "critical" : e.contains(.warning) ? "warning" : "normal"
                Log.warn("memory", "Kernel memory pressure event: \(self.pressureLevel)")
                self.sample()
            }
            src.resume()
            self.pressureSource = src
        }
    }

    private func restartTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let ms = max(100, config.pollIntervalMs)
        t.schedule(deadline: .now(), repeating: .milliseconds(ms), leeway: .milliseconds(ms / 10))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    private func sample() {
        var s = MemoryMonitor.readSnapshotRaw()
        let threshold = thresholdBox.get()
        s.pressure = pressureLevel
        s.thresholdBytes = threshold

        let wasOpen = breaker.get()
        var open = wasOpen
        let critical = pressureLevel == "critical"
        let warningLow = pressureLevel == "warning" && s.availableBytes < threshold + threshold / 2
        if !wasOpen {
            if s.availableBytes < threshold || critical || warningLow {
                open = true
                healthySince = nil
            }
        } else {
            // Hysteresis: close only after RAM stays above threshold + margin for recoverySeconds.
            let recovered = s.availableBytes > threshold + bytes(fromGiB: config.hysteresisGB) && pressureLevel == "normal"
            if recovered {
                let now = monotonicMs()
                if healthySince == nil { healthySince = now }
                if now - (healthySince ?? now) >= config.recoverySeconds * 1000 { open = false; healthySince = nil }
            } else { healthySince = nil }
        }
        s.breakerOpen = open
        snapshotBox.set(s)
        let nowTs = Date().timeIntervalSince1970
        if nowTs - lastHistoryAt >= historyInterval {
            lastHistoryAt = nowTs
            let point = MemoryPoint(t: nowTs, available: s.availableBytes,
                                    used: s.totalBytes > s.availableBytes ? s.totalBytes - s.availableBytes : 0,
                                    swap: s.swapUsedBytes, breaker: open)
            historyBox.mutate { h in
                h.append(point)
                if h.count > historyCapacity { h.removeFirst(h.count - historyCapacity) }
            }
        }
        if open != wasOpen {
            breaker.set(open)
            Log.warn("memory", String(format: "Circuit breaker %@ (available %.2f GiB, threshold %.2f GiB, pressure %@)",
                                      open ? "OPEN" : "CLOSED", gib(s.availableBytes), gib(threshold), pressureLevel))
            onBreakerChange?(open, s)
        }
    }

    /// Reads host_statistics64(HOST_VM_INFO64) + vm.swapusage.
    static func readSnapshotRaw() -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        guard kr == KERN_SUCCESS else {
            return MemorySnapshot(timestamp: Date(), totalBytes: total, availableBytes: total / 2, freeBytes: 0, activeBytes: 0,
                                  inactiveBytes: 0, wiredBytes: 0, compressedBytes: 0, purgeableBytes: 0, fileBackedBytes: 0,
                                  swapUsedBytes: swap.xsu_used, swapoutsTotal: 0, pressure: "unknown", breakerOpen: false, thresholdBytes: 0)
        }
        let ps = pageSize
        let free = UInt64(stats.free_count) * ps
        let speculative = UInt64(stats.speculative_count) * ps
        let purgeable = UInt64(stats.purgeable_count) * ps
        let external = UInt64(stats.external_page_count) * ps   // file-backed (reclaimable without swap)
        let available = min(total, free + speculative + purgeable + external)
        return MemorySnapshot(
            timestamp: Date(),
            totalBytes: total,
            availableBytes: available,
            freeBytes: free + speculative,
            activeBytes: UInt64(stats.active_count) * ps,
            inactiveBytes: UInt64(stats.inactive_count) * ps,
            wiredBytes: UInt64(stats.wire_count) * ps,
            compressedBytes: UInt64(stats.compressor_page_count) * ps,
            purgeableBytes: purgeable,
            fileBackedBytes: external,
            swapUsedBytes: swap.xsu_used,
            swapoutsTotal: stats.swapouts,
            pressure: "normal",
            breakerOpen: false,
            thresholdBytes: 0
        )
    }
}
