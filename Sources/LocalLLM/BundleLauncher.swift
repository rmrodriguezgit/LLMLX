import Foundation
import AppKit

/// Auto-updated builds live in Application Support/LocalLLM/bin as `LocalLLM-<commit>.app` bundles
/// and are started through LaunchServices, never with `execv`/`Process`.
///
/// macOS only shows the menu bar item of a process whose executable belongs to the bundle it is
/// registered under. An `execv` keeps the registration of /Applications/LocalLLM.app while running
/// another file, and a bare `Process` has no bundle at all: in both cases the app runs (gateway,
/// Ollama) but its icon never appears in the menu bar.
enum BundleLauncher {
    /// `…/X.app/Contents/MacOS/exe` -> `…/X.app`, or nil for a loose binary.
    static func bundle(containing executable: URL) -> URL? {
        let b = executable.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return b.pathExtension == "app" ? b : nil
    }

    /// Wraps a freshly built binary into `<dest>.app` with the installed bundle's Info.plist,
    /// so LaunchServices gives it the same identity (bundle id, LSUIElement) as the installed app.
    static func makeBundle(binary: URL, at dest: URL, baseBundle: URL?, version: String?) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        let macOS = dest.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let exe = macOS.appendingPathComponent("LocalLLM")
        try fm.copyItem(at: binary, to: exe)

        var info: [String: Any] = [:]
        if let base = baseBundle,
           let data = try? Data(contentsOf: base.appendingPathComponent("Contents/Info.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            info = plist
        }
        info["CFBundleExecutable"] = "LocalLLM"
        info["CFBundlePackageType"] = "APPL"
        info["LSUIElement"] = true
        if info["CFBundleIdentifier"] == nil { info["CFBundleIdentifier"] = "com.llmlx.localllm" }
        if let version { info["CFBundleShortVersionString"] = version }
        let out = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try out.write(to: dest.appendingPathComponent("Contents/Info.plist"))
        // Ad-hoc sign the whole bundle so the executable and Info.plist are sealed together.
        let sign = ProcessRunner.runSync("/usr/bin/codesign", ["--force", "--sign", "-", dest.path], timeout: 60)
        if !sign.ok { Log.warn("launcher", "codesign \(dest.lastPathComponent) failed: \(sign.combined)") }
        return exe
    }

    /// Starts a new instance of `bundle` through LaunchServices with the given extra environment.
    /// Blocks until LaunchServices answers (or `timeout`); safe to call before NSApplication runs.
    static func open(bundle: URL, environment: [String: String], arguments: [String] = [],
                     timeout: TimeInterval = 30) -> NSRunningApplication? {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.addsToRecentItems = false
        config.promptsUserIfNeeded = false
        config.arguments = arguments
        // Carry every LOCALLLM_* setting of this process (home, port, …) plus the overrides.
        var env = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("LOCALLLM_") }
        environment.forEach { env[$0.key] = $0.value }
        config.environment = env

        let result = Locked<NSRunningApplication?>(nil)
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: bundle, configuration: config) { app, error in
            if let error { Log.error("launcher", "LaunchServices could not open \(bundle.path): \(error.localizedDescription)") }
            result.set(app)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            Log.error("launcher", "LaunchServices did not answer within \(Int(timeout))s for \(bundle.path)")
            return nil
        }
        return result.get()
    }
}
