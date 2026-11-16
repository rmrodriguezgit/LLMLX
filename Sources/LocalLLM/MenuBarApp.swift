import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Entry point

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--health-check") {
            let port = args.firstIndex(of: "--port").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 0
            runHeadless(.healthCheck(port: port))
        }
        if args.contains("--headless") { runHeadless(.headless) }
        Launcher.redirectIfUpdated()
        LocalLLMApp.main()
    }

    private static func runHeadless(_ mode: RunMode) -> Never {
        Task { await AppCoordinator.shared.start(mode: mode) }
        dispatchMain()
    }
}

// MARK: - SwiftUI app (LSUIElement menu bar extra)

struct LocalLLMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView().environmentObject(state)
        } label: {
            Image(systemName: state.snapshot.breakerOpen ? "exclamationmark.triangle.fill" : (state.snapshot.inFlight > 0 ? "cpu.fill" : "cpu"))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also needed when running an auto-updated binary outside the .app (no Info.plist LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        Task { await AppCoordinator.shared.start(mode: .app) }
        Task { @MainActor in AppState.shared.startPolling() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateNow }
        terminating = true
        Task {
            await AppCoordinator.shared.shutdown(handoff: false)
            await MainActor.run { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

// MARK: - UI state

struct UISnapshot {
    var hardwareLine = "Detectando hardware…"
    var gpuLine = ""
    var profileLine = ""
    var model = "—"
    var engine = "—"
    var totalBytes: UInt64 = 1
    var weightsBytes: UInt64 = 0
    var kvBytes: UInt64 = 0
    var otherUsedBytes: UInt64 = 0
    var availableBytes: UInt64 = 0
    var thresholdBytes: UInt64 = 0
    var swapBytes: UInt64 = 0
    var pressure = "normal"
    var breakerOpen = false
    var inFlight = 0
    var queued = 0
    var capacity = 0
    var sessionRequests = 0
    var totalRequests = 0
    var totalPromptTokens = 0
    var totalCompletionTokens = 0
    var lastTokS: Double?
    var lastTtft: Double?
    var gitState = "idle"
    var gitCommit = "—"
    var gitSubject = ""
    var gitLastSync: Date?
    var gitLastOutcome = ""
    var runningCommit = ""
    var gatewayURL = ""
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var snapshot = UISnapshot()
    @Published var syncing = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var timer: Timer?

    func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in AppState.shared.refresh() }
        }
    }

    func refresh() {
        let app = AppCoordinator.shared
        let hw = app.hardware
        let plan = app.plan
        let mem = app.memory.snapshot
        let loaded = app.ollama.loadedModels
        let a = app.admission.stats
        let all = app.tracker.allTimeStats
        let live = app.tracker.liveStats
        let git = app.updater.status
        let cfg = app.config.current

        var s = UISnapshot()
        s.hardwareLine = hw.summary
        s.gpuLine = "\(hw.performanceCores)P + \(hw.efficiencyCores)E CPU • \(hw.gpuCores.map { "\($0)-core GPU" } ?? "GPU")"
        s.profileLine = "\(plan.profileId) • ctx \(plan.numCtx) • ×\(plan.numParallel) • KV \(plan.kvCacheType)"
        s.model = plan.model
        s.engine = app.ollama.status.label
        s.totalBytes = max(1, mem.totalBytes)
        s.weightsBytes = loaded.reduce(0) { $0 + $1.weightsBytes }
        s.kvBytes = loaded.reduce(0) { $0 + $1.kvCacheBytes }
        let used = mem.totalBytes > mem.availableBytes ? mem.totalBytes - mem.availableBytes : 0
        let modelResident = s.weightsBytes + s.kvBytes
        s.otherUsedBytes = used > modelResident ? used - modelResident : 0
        s.availableBytes = mem.availableBytes
        s.thresholdBytes = mem.thresholdBytes
        s.swapBytes = mem.swapUsedBytes
        s.pressure = mem.pressure
        s.breakerOpen = mem.breakerOpen
        s.inFlight = a.inFlight
        s.queued = a.queued
        s.capacity = a.capacity
        s.sessionRequests = live.requests
        s.totalRequests = all.requests
        s.totalPromptTokens = all.promptTokens
        s.totalCompletionTokens = all.completionTokens
        s.lastTokS = live.lastTokensPerSec
        s.lastTtft = live.lastTtftMs
        s.gitState = git.state
        s.gitCommit = git.headCommit.map { String($0.prefix(8)) } ?? "—"
        s.gitSubject = git.headSubject ?? ""
        s.gitLastSync = git.lastSyncAt
        s.gitLastOutcome = git.lastReport.map { "\($0.outcome): \($0.detail)" } ?? ""
        s.runningCommit = String(AppEnvironment.runningCommit.prefix(8))
        s.gatewayURL = "http://\(cfg.gateway.host):\(app.gateway.boundPort == 0 ? cfg.gateway.port : app.gateway.boundPort)"
        snapshot = s
    }

    func syncGit() {
        syncing = true
        Task {
            _ = await AppCoordinator.shared.updater.syncNow(trigger: .manual, waitForBuild: false)
            await MainActor.run { self.syncing = false; self.refresh() }
        }
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { Log.warn("ui", "Launch at login toggle failed: \(error.localizedDescription)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Views

private func fmtGB(_ b: UInt64) -> String { String(format: "%.1f GB", gib(b)) }
private func fmtCount(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.2fM", Double(n) / 1e6) : n >= 10_000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
}

struct MenuContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let s = state.snapshot
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.hardwareLine).font(.headline)
                    Text(s.gpuLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(s.breakerOpen ? Color.red : (s.engine.hasPrefix("Listo") ? Color.green : Color.orange)).frame(width: 10, height: 10)
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Label(s.model, systemImage: "brain").font(.system(.body, design: .monospaced))
                Text(s.engine).font(.caption).foregroundStyle(.secondary)
                Text(s.profileLine).font(.caption2).foregroundStyle(.secondary)
            }

            MemoryBar(snapshot: s)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    stat("Activas", "\(s.inFlight)/\(s.capacity)")
                    stat("En cola", "\(s.queued)")
                    stat("tok/s", s.lastTokS.map { String(format: "%.1f", $0) } ?? "—")
                }
                GridRow {
                    stat("Peticiones", fmtCount(s.totalRequests))
                    stat("Tokens in", fmtCount(s.totalPromptTokens))
                    stat("Tokens out", fmtCount(s.totalCompletionTokens))
                }
                GridRow {
                    stat("TTFT", s.lastTtft.map { String(format: "%.0f ms", $0) } ?? "—")
                    stat("Presión", s.pressure)
                    stat("Swap", fmtGB(s.swapBytes))
                }
            }

            if s.breakerOpen {
                Label("Circuit breaker activo: RAM libre < \(fmtGB(s.thresholdBytes)). Nuevas peticiones reciben 429.",
                      systemImage: "exclamationmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: "arrow.triangle.branch")
                    Text("Git \(s.gitCommit)").font(.system(.caption, design: .monospaced))
                    Text("• \(s.gitState)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("bin \(s.runningCommit)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
                if !s.gitSubject.isEmpty { Text(s.gitSubject).font(.caption).lineLimit(1) }
                if let d = s.gitLastSync {
                    Text("Última sync: \(d.formatted(date: .omitted, time: .standard)) — \(s.gitLastOutcome)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Button {
                    state.syncGit()
                } label: {
                    Label(state.syncing ? "Sincronizando…" : "Sincronizar Git Ahora", systemImage: "arrow.clockwise")
                }
                .disabled(state.syncing)
            }

            Divider()

            HStack {
                Button("Copiar URL API") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s.gatewayURL + "/v1", forType: .string)
                }
                Button("Métricas") { NSWorkspace.shared.open(URL(string: s.gatewayURL + "/v1/metrics")!) }
                Button("Perfil") { NSWorkspace.shared.open(URL(string: s.gatewayURL + "/v1/hardware-profile")!) }
            }
            .buttonStyle(.link)
            .font(.caption)

            HStack {
                Toggle("Abrir al iniciar sesión", isOn: Binding(get: { state.launchAtLogin }, set: { _ in state.toggleLaunchAtLogin() }))
                    .toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button("Salir") { NSApp.terminate(nil) }
            }
            Text(s.gatewayURL).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 360)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced))
        }
    }
}

struct MemoryBar: View {
    let snapshot: UISnapshot

    var body: some View {
        let s = snapshot
        let total = Double(s.totalBytes)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    segment(.blue, Double(s.weightsBytes) / total, geo.size.width)
                    segment(.purple, Double(s.kvBytes) / total, geo.size.width)
                    segment(.gray.opacity(0.6), Double(s.otherUsedBytes) / total, geo.size.width)
                    segment(s.breakerOpen ? .red : .green.opacity(0.7), Double(s.availableBytes) / total, geo.size.width)
                    Spacer(minLength: 0)
                }
                .overlay(alignment: .leading) {
                    // Safety threshold marker (circuit breaker opens when "Libre" drops below it).
                    Rectangle().fill(Color.red).frame(width: 1.5)
                        .offset(x: geo.size.width * (1 - Double(s.thresholdBytes) / total))
                }
            }
            .frame(height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            HStack(spacing: 10) {
                legend(.blue, "Pesos \(fmtGB(s.weightsBytes))")
                legend(.purple, "KV \(fmtGB(s.kvBytes))")
                legend(.gray, "Otros \(fmtGB(s.otherUsedBytes))")
                legend(.green, "Libre \(fmtGB(s.availableBytes))")
            }
            .font(.caption2)
        }
    }

    private func segment(_ color: Color, _ fraction: Double, _ width: CGFloat) -> some View {
        Rectangle().fill(color).frame(width: max(0, width * CGFloat(min(1, max(0, fraction)))))
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) { Circle().fill(color).frame(width: 6, height: 6); Text(text) }
    }
}
