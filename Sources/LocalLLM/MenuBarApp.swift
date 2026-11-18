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
        #if DEBUG
        // Dev aid: renders the menu bar popover to a PNG (`--snapshot-menu out.png`) for UI review.
        if let i = args.firstIndex(of: "--snapshot-menu"), args.indices.contains(i + 1) { snapshotMenu(to: args[i + 1]) }
        #endif
        let headless = args.contains("--headless")
        if !headless { Launcher.redirectIfUpdated() }
        InstanceLock.acquireOrExit()
        if headless { runHeadless(.headless) }
        LocalLLMApp.main()
    }

    #if DEBUG
    private static func snapshotMenu(to path: String) -> Never {
        Task { await AppCoordinator.shared.start(mode: .headless) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            do {
                AppState.shared.refresh()
                let view = MenuContentView().environmentObject(AppState.shared).background(Color(nsColor: .windowBackgroundColor))
                let r = ImageRenderer(content: view)
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                Task { await AppCoordinator.shared.shutdown(handoff: false); exit(0) }
            }
        }
        NSApplication.shared.run()
        exit(0)
    }
    #endif

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

struct ProviderOption: Identifiable, Equatable {
    let id: String
    let name: String
    let usable: Bool
    let models: [String]
}

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
    var autoModel = ""
    var modelOverride: String?
    var installedModels: [String] = []
    /// Enabled remote APIs, as configured in the admin panel (re-read every refresh).
    var providers: [ProviderOption] = []
    var activeIsRemote = false
    /// nil = local engine (Ollama).
    var activeProviderId: String?
    /// Model shown in the "Modelo" picker: bare remote name or local model.
    var activeModelShort = "—"
    var providersError: String?
    var loadedLine = ""
    var lastUsedModel: String?
    var displayVersion = ""
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
        // providers.json is re-read when it changes, so edits in Admin show up here within a second.
        let pf = app.providers.current
        s.providers = pf.providers.filter { $0.enabled && !$0.isLocal }.map {
            ProviderOption(id: $0.id, name: $0.name, usable: $0.hasKey || ProviderPicker.isOnThisMac($0.resolvedBaseURL),
                           models: $0.offeredModels)
        }
        s.providersError = app.providers.loadError
        if let p = pf.providers.first(where: { $0.id == pf.defaultProvider && $0.enabled && !$0.isLocal }) {
            s.activeProviderId = p.id
            s.activeIsRemote = true
            s.activeModelShort = (p.defaultModel ?? "").isEmpty ? (p.offeredModels.first ?? "—") : p.defaultModel!
            s.model = "\(p.id)/\(s.activeModelShort)"
        } else {
            s.activeProviderId = nil
            s.activeIsRemote = false
            s.activeModelShort = plan.model
            s.model = plan.model
        }
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
        s.autoModel = app.autoModel
        s.modelOverride = app.modelOverride
        s.installedModels = app.ollama.installedModels.keys.sorted()
        s.lastUsedModel = live.lastModel
        if loaded.isEmpty {
            s.loadedLine = mem.breakerOpen || app.tracker.liveStats.requests > 0
                ? "En memoria: ninguno (se descarga por inactividad o memoria baja; se recarga en la próxima petición)"
                : "En memoria: ninguno (se carga con la primera petición)"
        } else {
            s.loadedLine = "En memoria: " + loaded.map { "\($0.name) \(fmtGB($0.sizeBytes))" }.joined(separator: ", ")
        }
        s.displayVersion = "LocalLLM \(AppEnvironment.displayVersion)"
        s.gatewayURL = "http://\(cfg.gateway.host):\(app.gateway.boundPort == 0 ? cfg.gateway.port : app.gateway.boundPort)"
        snapshot = s
    }

    /// Makes `id` the provider that answers "default" / aliases ("local" = Ollama on this Mac).
    /// `model` also becomes that API's default model. Written to providers.json, same as Admin.
    func selectProvider(_ id: String, model: String? = nil) {
        do {
            try AppCoordinator.shared.providers.select(provider: id, model: model)
            AppCoordinator.shared.tracker.incident("provider-selected", "menu: \(id)\(model.map { "/" + $0 } ?? "")")
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
        refresh()
    }

    /// Local model: switches the provider to "local" and picks the Ollama model (nil = automatic).
    func selectLocalModel(_ model: String?) {
        if snapshot.activeIsRemote { selectProvider("local") }
        selectModel(model)
    }

    @Published var actionError: String?

    func openAdmin(_ route: String = "") {
        let base = snapshot.gatewayURL.isEmpty ? "http://127.0.0.1:11500" : snapshot.gatewayURL
        if let url = URL(string: base + "/dashboard/" + (route.isEmpty ? "" : "#/" + route)) { NSWorkspace.shared.open(url) }
    }

    func selectModel(_ model: String?) {
        Task {
            _ = await AppCoordinator.shared.setModel(model)
            await MainActor.run { self.refresh() }
        }
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

func fmtGB(_ b: UInt64) -> String { String(format: "%.1f GB", gib(b)) }
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

            ProviderPicker(snapshot: s)

            VStack(alignment: .leading, spacing: 3) {
                Text(s.activeIsRemote ? "Motor local en espera (solo para apps que lo pidan)" : "Motor local: \(s.engine)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !s.activeIsRemote {
                    Text(s.loadedLine).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let last = s.lastUsedModel, last != s.model {
                    Text("Última petición usó: \(last)").font(.caption).foregroundStyle(.orange).lineLimit(1).truncationMode(.middle)
                }
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
                    Image(systemName: "arrow.down.circle")
                    Text("Actualizaciones automáticas").font(.caption.bold())
                    Text("• \(updateStateLabel(s.gitState))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .help("La app revisa GitHub (rmrodriguezgit/LLMLX) cada 15 min. Cambios de configuración se aplican al instante; cambios de código se compilan solos y la app se reinicia sin cortar peticiones.")
                Text("Último cambio: \(s.gitSubject.isEmpty ? "—" : s.gitSubject)").font(.caption).lineLimit(1)
                if let d = s.gitLastSync {
                    Text("Revisado \(d.formatted(date: .omitted, time: .shortened)) — \(updateOutcomeLabel(s.gitLastOutcome))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Button {
                    state.syncGit()
                } label: {
                    Label(state.syncing ? "Buscando…" : "Buscar actualizaciones ahora", systemImage: "arrow.clockwise")
                }
                .disabled(state.syncing)
            }

            Divider()

            Button {
                state.openAdmin()
            } label: {
                Label("Admin", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .help("Abre el panel de administración: proveedores LLM, chat, métricas, memoria, perfil y actualizaciones")

            HStack {
                Toggle("Abrir al iniciar sesión", isOn: Binding(get: { state.launchAtLogin }, set: { _ in state.toggleLaunchAtLogin() }))
                    .toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button("Salir") { NSApp.terminate(nil) }
            }
            HStack {
                Text(s.displayVersion).font(.system(.caption2, design: .monospaced))
                Spacer()
                Text(s.gatewayURL).font(.system(.caption2, design: .monospaced))
            }
            .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 360)
        // The window takes the content's full height, so wrapped lines never get drawn on top of each other.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced))
        }
    }
}

/// "Proveedor de LLM": which engine answers the apps that ask for "default" / "local" / an alias.
struct ProviderPicker: View {
    @EnvironmentObject var state: AppState
    let snapshot: UISnapshot

    private var current: ProviderOption? { snapshot.providers.first { $0.id == snapshot.activeProviderId } }

    var body: some View {
        let s = snapshot
        VStack(alignment: .leading, spacing: 7) {
            Text("PROVEEDOR DE LLM").font(.caption2.bold()).foregroundStyle(.secondary)

            row("Proveedor") {
                Menu {
                    Button { state.selectProvider("local") } label: {
                        check(s.activeProviderId == nil, "Local en este Mac (Ollama) · predeterminado")
                    }
                    if !s.providers.isEmpty {
                        Section("APIs") {
                            ForEach(s.providers) { p in
                                Button { state.selectProvider(p.id) } label: {
                                    check(s.activeProviderId == p.id,
                                          p.name + (!p.usable ? " — sin API key" : ""))
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Añadir o editar proveedores…") { state.openAdmin("proveedores") }
                } label: {
                    Label(current?.name ?? "Local (Ollama)", systemImage: s.activeIsRemote ? "cloud" : "desktopcomputer")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            row("Modelo") {
                Menu {
                    if let p = current {
                        ForEach(p.models, id: \.self) { m in
                            Button { state.selectProvider(p.id, model: m) } label: { check(s.activeModelShort == m, m) }
                        }
                    } else {
                        Button { state.selectLocalModel(nil) } label: {
                            check(s.modelOverride == nil, "Automático — el mejor para este Mac (\(s.autoModel))")
                        }
                        Divider()
                        ForEach(s.installedModels, id: \.self) { m in
                            Button { state.selectLocalModel(m) } label: { check(s.modelOverride == m, m) }
                        }
                    }
                } label: {
                    Text(s.activeModelShort).font(.system(.body, design: .monospaced))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if !s.activeIsRemote {
                    Text(s.modelOverride == nil ? "auto" : "manual")
                        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
            }

            Text(s.activeIsRemote ? "Tus apps usan este proveedor por la red." : "Tus apps usan este Mac, sin internet.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let err = state.actionError ?? s.providersError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("Lo usan todas las apps que piden \"default\", \"local\" o un alias (gpt-4o…) en \(s.gatewayURL). Los proveedores se configuran en Admin → Proveedores LLM.")
    }

    static func isOnThisMac(_ url: URL?) -> Bool {
        let h = url?.host ?? ""
        return h == "127.0.0.1" || h == "localhost" || h == "::1"
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func check(_ on: Bool, _ text: String) -> some View {
        if on { Label(text, systemImage: "checkmark") } else { Text(text) }
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

private func updateStateLabel(_ state: String) -> String {
    switch state {
    case "idle": return "al día"
    case "fetching": return "buscando cambios…"
    case "pulling": return "descargando cambios…"
    case "building": return "compilando nueva versión…"
    case "health-check": return "probando nueva versión…"
    case "restarting": return "reiniciando…"
    case "git-unavailable": return "git no disponible"
    case "clone-failed": return "sin conexión con GitHub"
    default: return state
    }
}

private func updateOutcomeLabel(_ outcome: String) -> String {
    let kind = outcome.split(separator: ":").first.map(String.init) ?? outcome
    switch kind {
    case "up-to-date": return "sin cambios nuevos"
    case "hot-reloaded": return "configuración aplicada"
    case "rebuilding": return "compilando en segundo plano"
    case "rebuilt": return "nueva versión instalada"
    case "rolled-back": return "cambio rechazado (se mantuvo la versión anterior)"
    case "pulled": return "cambios descargados"
    case "failed": return "error al revisar: " + outcome.dropFirst(kind.count + 1).trimmingCharacters(in: .whitespaces)
    case "skipped": return "omitido"
    default: return outcome
    }
}
