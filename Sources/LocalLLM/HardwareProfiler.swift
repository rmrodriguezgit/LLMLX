import Foundation
import IOKit
import Metal

// MARK: - Detected hardware

struct HardwareInfo: Codable, Equatable {
    var chip: String
    var modelIdentifier: String
    var isAppleSilicon: Bool
    var performanceCores: Int
    var efficiencyCores: Int
    var logicalCores: Int
    var gpuCores: Int?
    var gpuName: String?
    var totalMemoryBytes: UInt64
    var availableMemoryBytesAtLaunch: UInt64
    var metalRecommendedWorkingSetBytes: UInt64?
    var osVersion: String

    var summary: String {
        let gb = Int((gib(totalMemoryBytes)).rounded())
        return "\(chip) • \(gb) GB"
    }
}

struct MemoryEstimate: Codable, Equatable {
    var weightsBytes: UInt64
    var kvCacheBytes: UInt64
    var overheadBytes: UInt64
    var totalBytes: UInt64
    var budgetBytes: UInt64
    var headroomBytes: Int64
}

/// Result of the decision matrix: what we run and why.
struct ModelPlan: Codable, Equatable {
    var profileId: String
    var profileDescription: String
    var model: String
    var fallbackModels: [String]
    var quantization: String
    var numCtx: Int
    var numParallel: Int
    var kvCacheType: String
    var flashAttention: Bool
    var numGPU: Int
    var metalBudgetBytes: UInt64
    var minFreeBytes: UInt64
    var estimate: MemoryEstimate
    var reasons: [String]
    var adjustments: [String]
}

// MARK: - Profiler

enum HardwareProfiler {

    static func detect() -> HardwareInfo {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Unknown CPU"
        let arm64 = (sysctlInt("hw.optional.arm64") ?? 0) == 1
        let pCores = sysctlInt("hw.perflevel0.physicalcpu") ?? sysctlInt("hw.physicalcpu") ?? 1
        let eCores = sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        let logical = sysctlInt("hw.logicalcpu") ?? pCores + eCores
        let mem = UInt64(sysctlInt64("hw.memsize") ?? 0)
        let (gpuCores, gpuName) = appleGPU()
        let metalDevice = MTLCreateSystemDefaultDevice()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return HardwareInfo(
            chip: chip,
            modelIdentifier: sysctlString("hw.model") ?? "Mac",
            isAppleSilicon: arm64,
            performanceCores: pCores,
            efficiencyCores: eCores,
            logicalCores: logical,
            gpuCores: gpuCores,
            gpuName: gpuName ?? metalDevice?.name,
            totalMemoryBytes: mem,
            availableMemoryBytesAtLaunch: MemoryMonitor.readSnapshotRaw().availableBytes,
            metalRecommendedWorkingSetBytes: metalDevice.map { UInt64($0.recommendedMaxWorkingSetSize) },
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        )
    }

    /// Decision matrix. Picks the tier by unified memory, then verifies the memory plan
    /// (weights + KV cache + compute buffers) fits the Metal budget, shrinking context,
    /// then parallelism, then dropping to a smaller tier until it fits.
    static func select(hardware hw: HardwareInfo, config: RemoteConfig) -> ModelPlan {
        let env = ProcessInfo.processInfo.environment
        let rules = config.profiles.sorted { $0.minMemoryGB < $1.minMemoryGB }
        let totalGB = gib(hw.totalMemoryBytes)
        var reasons: [String] = []
        var adjustments: [String] = []

        var index: Int
        if let forced = env["LOCALLLM_FORCE_PROFILE"], let i = rules.firstIndex(where: { $0.id == forced }) {
            index = i
            reasons.append("Profile forced by LOCALLLM_FORCE_PROFILE=\(forced)")
        } else if let i = rules.lastIndex(where: { totalGB >= $0.minMemoryGB && totalGB < $0.maxMemoryGB }) {
            index = i
            reasons.append(String(format: "Detected %.1f GiB unified memory -> profile '%@' (%.0f-%.0f GB)",
                                  totalGB, rules[i].id, rules[i].minMemoryGB, rules[i].maxMemoryGB))
        } else {
            index = totalGB < (rules.first?.minMemoryGB ?? 0) ? 0 : rules.count - 1
            reasons.append(String(format: "%.1f GiB outside every range; using nearest profile '%@'", totalGB, rules[index].id))
        }
        reasons.append("Chip: \(hw.chip), \(hw.performanceCores)P+\(hw.efficiencyCores)E cores, GPU cores: \(hw.gpuCores.map(String.init) ?? "n/a")")

        while true {
            let rule = rules[index]
            var budget = bytes(fromGiB: rule.metalBudgetGB)
            if let metal = hw.metalRecommendedWorkingSetBytes, metal > 0, metal < budget {
                adjustments.append(String(format: "Metal recommendedMaxWorkingSetSize %.2f GiB < profile budget %.2f GiB; using Metal value", gib(metal), rule.metalBudgetGB))
                budget = metal
            }
            // Never plan for more than total RAM minus a 4 GiB reserve for macOS + apps.
            let osReserveCap = hw.totalMemoryBytes > bytes(fromGiB: 6) ? hw.totalMemoryBytes - bytes(fromGiB: 4) : hw.totalMemoryBytes / 2
            if budget > osReserveCap { budget = osReserveCap; adjustments.append("Budget capped to RAM - 4 GiB") }

            var ctx = rule.numCtx
            var parallel = rule.numParallel
            var est = estimate(rule, ctx: ctx, parallel: parallel, budget: budget)
            while est.totalBytes > budget {
                if ctx / 2 >= rule.minCtx {
                    ctx /= 2
                    adjustments.append("Plan exceeded budget; num_ctx reduced to \(ctx)")
                } else if parallel > 1 {
                    parallel -= 1
                    adjustments.append("Plan exceeded budget; num_parallel reduced to \(parallel)")
                } else { break }
                est = estimate(rule, ctx: ctx, parallel: parallel, budget: budget)
            }

            if est.totalBytes > budget && index > 0 {
                adjustments.append("Profile '\(rule.id)' cannot fit \(String(format: "%.2f", gib(budget))) GiB; downgrading to '\(rules[index - 1].id)'")
                index -= 1
                continue
            }

            var model = rule.model
            if let forced = env["LOCALLLM_FORCE_MODEL"], !forced.isEmpty {
                model = forced
                adjustments.append("Model forced by LOCALLLM_FORCE_MODEL=\(forced)")
            }
            reasons.append(String(format: "Model %@ (%@): weights≈%.2f GiB + KV(%@, %d×%d tok)≈%.2f GiB + compute≈%.2f GiB = %.2f GiB of %.2f GiB budget",
                                  model, rule.quantization, gib(est.weightsBytes), rule.kvCacheType, parallel, ctx,
                                  gib(est.kvCacheBytes), gib(est.overheadBytes), gib(est.totalBytes), gib(budget)))
            reasons.append(String(format: "Circuit breaker opens when available RAM < %.1f GiB", rule.minFreeGB))

            let gpu = hw.isAppleSilicon
            if !gpu { adjustments.append("Not Apple Silicon: Metal offload disabled (num_gpu=0)") }
            return ModelPlan(
                profileId: rule.id,
                profileDescription: rule.description,
                model: model,
                fallbackModels: rule.fallbackModels,
                quantization: rule.quantization,
                numCtx: ctx,
                numParallel: parallel,
                kvCacheType: rule.kvCacheType,
                flashAttention: gpu && rule.flashAttention,
                numGPU: gpu ? rule.numGPU : 0,
                metalBudgetBytes: budget,
                minFreeBytes: bytes(fromGiB: rule.minFreeGB),
                estimate: est,
                reasons: reasons,
                adjustments: adjustments
            )
        }
    }

    static func estimate(_ rule: HardwareProfileRule, ctx: Int, parallel: Int, budget: UInt64) -> MemoryEstimate {
        let kvFactor: Double
        switch rule.kvCacheType {
        case "q8_0": kvFactor = 0.53   // 8.5 bits per element incl. block scales
        case "q4_0": kvFactor = 0.28
        default: kvFactor = 1.0
        }
        let weights = bytes(fromGiB: rule.estimatedWeightsGB)
        let kv = UInt64(Double(rule.kvBytesPerTokenF16) * kvFactor * Double(ctx) * Double(parallel))
        let overhead = bytes(fromGiB: rule.computeOverheadGB)
        let total = weights + kv + overhead
        return MemoryEstimate(weightsBytes: weights, kvCacheBytes: kv, overheadBytes: overhead,
                              totalBytes: total, budgetBytes: budget, headroomBytes: Int64(budget) - Int64(total))
    }

    // MARK: sysctl

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func sysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    // MARK: IOKit — Apple GPU core count lives on the AGXAccelerator service

    static func appleGPU() -> (Int?, String?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == KERN_SUCCESS else {
            return (nil, nil)
        }
        defer { IOObjectRelease(iterator) }
        var cores: Int?
        var name: String?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if cores == nil,
               let v = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                cores = (v as? NSNumber)?.intValue
            }
            if name == nil,
               let v = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                if let s = v as? String { name = s }
                else if let d = v as? Data { name = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .controlCharacters) }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (cores, name)
    }
}
