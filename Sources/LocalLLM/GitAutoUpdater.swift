import Foundation

struct SyncReport: Codable {
    var trigger: String
    var outcome: String          // up-to-date | hot-reloaded | rebuilding | rebuilt | rolled-back | failed | skipped
    var detail: String
    var fromCommit: String?
    var toCommit: String?
    var changedFiles: [String] = []
    var configReloaded = false
    var codeChanged = false
    var finishedAt = Date()
}

struct UpdaterStatus: Codable {
    var state = "idle"
    var remote = ""
    var branch = "main"
    var repoPath = AppPaths.repo.path
    var runningCommit = AppEnvironment.runningCommit
    var lastSyncAt: Date?
    var headCommit: String?
    var headSubject: String?
    var headDate: String?
    var lastReport: SyncReport?
    var pendingCodeCommit: String?
    var badCommits: [String] = []
    var nextSyncAt: Date?
}

/// Keeps a local clone of the configuration/code repository in sync with the remote.
///  - Level 1: config/ changes  -> validated hot-reload, zero downtime.
///  - Level 2: Sources/ changes -> background `swift build` on efficiency cores, candidate
///             health-check, atomic binary swap and blue/green restart with graceful drain.
///  - Any failure -> `git reset --hard ORIG_HEAD` + incident record, commit marked bad.
final class GitAutoUpdater {
    enum Trigger: String { case startup, timer, manual, api }

    private unowned let app: AppCoordinator
    private let statusBox: Locked<UpdaterStatus>
    private let busy = Locked<Bool>(false)
    private var timer: DispatchSourceTimer?
    private let buildLog = AppPaths.logs.appendingPathComponent("auto-update-build.log")

    init(app: AppCoordinator) {
        self.app = app
        var s = (try? JSONDecoder.iso.decode(UpdaterStatus.self, from: Data(contentsOf: AppPaths.updaterState))) ?? UpdaterStatus()
        s.state = "idle"
        s.runningCommit = AppEnvironment.runningCommit
        statusBox = Locked(s)
    }

    var status: UpdaterStatus { statusBox.get() }
    private var cfg: UpdaterConfig { app.config.current.updater }
    /// LOCALLLM_GIT_REMOTE (staging/dev override) > remote baked into Info.plist by build_dmg.sh > profiles.json.
    private var remote: String {
        if let e = ProcessInfo.processInfo.environment["LOCALLLM_GIT_REMOTE"], !e.isEmpty { return e }
        return AppEnvironment.bundledRemote.flatMap { $0.isEmpty ? nil : $0 } ?? cfg.remote
    }

    private func update(_ body: (inout UpdaterStatus) -> Void) {
        let s = statusBox.mutate { s -> UpdaterStatus in body(&s); return s }
        if let d = try? JSONEncoder.iso.encode(s) { try? d.write(to: AppPaths.updaterState, options: .atomic) }
    }

    // MARK: Scheduling

    func start() {
        guard cfg.enabled else { Log.info("git", "Auto-updater disabled by config"); return }
        Task {
            let hadRepo = FileManager.default.fileExists(atPath: AppPaths.repo.appendingPathComponent(".git").path)
            await ensureRepository()
            // First run: the clone now holds config/profiles.json, which takes precedence over the bundle copy.
            if !hadRepo { _ = await app.reloadConfig(reason: "repository initialised") }
            await refreshHead()
            _ = await syncNow(trigger: .startup, waitForBuild: true)
        }
        reschedule()
    }

    func reschedule() {
        timer?.cancel()
        guard cfg.enabled else { return }
        let interval = max(60, cfg.intervalMinutes * 60)
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(30))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.update { $0.nextSyncAt = Date().addingTimeInterval(interval) }
            Task { _ = await self.syncNow(trigger: .timer, waitForBuild: true) }
        }
        t.resume()
        timer = t
        update { $0.nextSyncAt = Date().addingTimeInterval(interval) }
    }

    // MARK: Git plumbing

    static let gitBinary: String? = {
        // Prefer the system git (/usr/bin/git), verified to actually work (CLT shim may be unconfigured).
        for path in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] where FileManager.default.isExecutableFile(atPath: path) {
            if ProcessRunner.runSync(path, ["--version"], timeout: 10).ok { return path }
        }
        return nil
    }()

    @discardableResult
    private func git(_ args: [String], timeout: TimeInterval = 120) async -> ProcessResult {
        guard let g = GitAutoUpdater.gitBinary else {
            return ProcessResult(status: -1, stdout: "", stderr: "git not available", timedOut: false)
        }
        return await ProcessRunner.run(g, ["-C", AppPaths.repo.path] + args,
                                       environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/true", "LC_ALL": "C"],
                                       timeout: timeout)
    }

    private func rev(_ ref: String) async -> String? {
        let r = await git(["rev-parse", "--verify", "--quiet", ref])
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !s.isEmpty ? s : nil
    }

    func ensureRepository() async {
        let fm = FileManager.default
        guard let g = GitAutoUpdater.gitBinary else {
            update { $0.state = "git-unavailable" }
            Log.error("git", "No working git binary (install Xcode Command Line Tools)")
            return
        }
        update { $0.remote = self.remote; $0.branch = self.cfg.branch }
        if fm.fileExists(atPath: AppPaths.repo.appendingPathComponent(".git").path) {
            await git(["remote", "set-url", "origin", remote])
            return
        }
        try? fm.removeItem(at: AppPaths.repo)
        let env = ["GIT_TERMINAL_PROMPT": "0"]
        // Seed from the bundle shipped inside the .app (offline first run), then point at the remote.
        if let seed = AppEnvironment.resourcesURL?.appendingPathComponent("seed.bundle"), fm.fileExists(atPath: seed.path) {
            let r = await ProcessRunner.run(g, ["clone", "--branch", cfg.branch, seed.path, AppPaths.repo.path], environment: env, timeout: 300)
            if r.ok {
                await git(["remote", "set-url", "origin", remote])
                Log.info("git", "Repository seeded from app bundle; origin -> \(remote)")
                return
            }
            Log.warn("git", "Seed clone failed: \(r.combined)")
        }
        let r = await ProcessRunner.run(g, ["clone", "--branch", cfg.branch, remote, AppPaths.repo.path], environment: env, timeout: 600)
        if r.ok { Log.info("git", "Cloned \(remote)") } else {
            Log.error("git", "Clone of \(remote) failed: \(r.combined)")
            update { $0.state = "clone-failed" }
        }
    }

    private func refreshHead() async {
        let r = await git(["log", "-1", "--format=%H%n%s%n%cI"])
        let lines = r.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard r.ok, lines.count >= 3 else { return }
        update { $0.headCommit = lines[0]; $0.headSubject = lines[1]; $0.headDate = lines[2] }
    }

    // MARK: Sync

    func syncNow(trigger: Trigger, waitForBuild: Bool) async -> SyncReport {
        let acquired = busy.mutate { b -> Bool in if b { return false }; b = true; return true }
        guard acquired else { return SyncReport(trigger: trigger.rawValue, outcome: "skipped", detail: "a sync is already running") }
        var releaseInDefer = true
        defer { if releaseInDefer { busy.set(false) } }

        update { $0.state = "fetching" }
        if !FileManager.default.fileExists(atPath: AppPaths.repo.appendingPathComponent(".git").path) { await ensureRepository() }
        let branch = cfg.branch
        var report = SyncReport(trigger: trigger.rawValue, outcome: "up-to-date", detail: "")

        let fetch = await git(["fetch", "--prune", "origin", branch], timeout: 180)
        guard fetch.ok else { return finish(failed: "git fetch failed: \(fetch.combined)", report) }
        guard let local = await rev("HEAD"), let remoteHead = await rev("origin/\(branch)") else {
            return finish(failed: "cannot resolve HEAD/origin/\(branch)", report)
        }
        report.fromCommit = local
        report.toCommit = remoteHead
        if local == remoteHead {
            report.detail = "already at \(local.prefix(8))"
            return finish(report)
        }
        if status.badCommits.contains(remoteHead) {
            report.outcome = "skipped"
            report.detail = "origin/\(branch) \(remoteHead.prefix(8)) previously failed health-check; waiting for a newer commit"
            return finish(report)
        }
        guard (await git(["merge-base", "--is-ancestor", "HEAD", "origin/\(branch)"])).ok else {
            app.tracker.incident("git-diverged", "local \(local.prefix(8)) is not an ancestor of origin/\(branch) \(remoteHead.prefix(8))")
            return finish(failed: "history diverged; fast-forward impossible", report)
        }

        let diff = await git(["diff", "--name-only", "HEAD", "origin/\(branch)"])
        report.changedFiles = diff.stdout.split(separator: "\n").map(String.init)
        update { $0.state = "pulling" }
        let pull = await git(["pull", "--ff-only", "origin", branch], timeout: 180)
        guard pull.ok else { return finish(failed: "git pull --ff-only failed: \(pull.combined)", report) }
        await refreshHead()

        let configChanged = report.changedFiles.contains { $0.hasPrefix("config/") }
        let codeChanged = report.changedFiles.contains { $0.hasPrefix("Sources/") || $0 == "Package.swift" || $0 == "Package.resolved" }
        report.codeChanged = codeChanged

        // Level 1 — hot reload
        if configChanged {
            let result = await app.reloadConfig(reason: "git \(remoteHead.prefix(8))")
            if !result.ok {
                await rollback(to: local, reason: "invalid configuration: \(result.detail)", bad: remoteHead)
                report.outcome = "rolled-back"
                report.detail = result.detail
                return finish(report)
            }
            report.configReloaded = true
            report.outcome = "hot-reloaded"
            report.detail = result.detail
        }

        // Level 2 — rebuild + blue/green
        if codeChanged {
            guard cfg.autoRebuild else {
                update { $0.pendingCodeCommit = remoteHead }
                report.detail += (report.detail.isEmpty ? "" : "; ") + "code changed, autoRebuild disabled"
                if report.outcome == "up-to-date" { report.outcome = "pulled" }
                return finish(report)
            }
            if waitForBuild {
                report = await rebuild(report, previous: local, target: remoteHead)
                return finish(report)
            }
            releaseInDefer = false
            report.outcome = "rebuilding"
            report.detail = "build of \(remoteHead.prefix(8)) started in background (efficiency cores)"
            update { $0.lastReport = report }
            Task.detached(priority: .background) {
                let final = await self.rebuild(report, previous: local, target: remoteHead)
                _ = self.finish(final)
                self.busy.set(false)
            }
            return report
        }
        if report.outcome == "up-to-date" { report.outcome = "pulled"; report.detail = "no config or code changes affecting the gateway" }
        return finish(report)
    }

    private func rebuild(_ input: SyncReport, previous: String, target: String) async -> SyncReport {
        var report = input
        guard let swift = ["/usr/bin/swift", "/Library/Developer/CommandLineTools/usr/bin/swift"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              ProcessRunner.runSync("/usr/bin/xcrun", ["--find", "swift"], timeout: 20).ok else {
            update { $0.pendingCodeCommit = target }
            app.tracker.incident("rebuild-skipped", "Swift toolchain not installed; code for \(target.prefix(8)) pending")
            report.outcome = report.configReloaded ? "hot-reloaded" : "pulled"
            report.detail += "; Swift toolchain missing, code update pending"
            return report
        }
        update { $0.state = "building" }
        let eCores = max(1, HardwareProfiler.sysctlInt("hw.perflevel1.physicalcpu") ?? 2)
        Log.info("git", "Building \(target.prefix(8)) with -j \(eCores) under background QoS (E-cores)")
        // taskpolicy -b => darwin background band: scheduled on efficiency cores, low I/O priority,
        // so inference on the P-cores/GPU is not disturbed.
        let build = await ProcessRunner.run("/usr/sbin/taskpolicy",
            ["-b", swift, "build", "-c", "release", "--arch", "arm64", "-j", String(eCores),
             "--package-path", AppPaths.repo.path, "--scratch-path", AppPaths.buildScratch.path],
            timeout: cfg.buildTimeoutMinutes * 60, qos: .background, appendLogTo: buildLog)
        guard build.ok else {
            await rollback(to: previous, reason: "swift build failed (see \(buildLog.path))", bad: target)
            report.outcome = "rolled-back"
            let errors = build.combined.split(separator: "\n").filter { $0.contains("error:") }.prefix(5).joined(separator: "\n")
            report.detail = "build failed: " + (errors.isEmpty ? String(build.combined.suffix(600)) : errors)
            return report
        }

        // Stage candidate binary
        let built = AppPaths.buildScratch.appendingPathComponent("arm64-apple-macosx/release/LocalLLM")
        let fallbackBuilt = AppPaths.buildScratch.appendingPathComponent("release/LocalLLM")
        let source = FileManager.default.fileExists(atPath: built.path) ? built : fallbackBuilt
        // Same versioning scheme as build_dmg.sh: 1.0.<number of commits>.
        let count = (await git(["rev-list", "--count", "HEAD"])).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let newVersion: String? = Int(count).map { "1.0.\($0)" }

        // Staged as an .app bundle: it is later opened through LaunchServices so the menu bar icon shows.
        let candidateBundle = AppPaths.binDir.appendingPathComponent("LocalLLM-\(target.prefix(12)).app")
        let candidate: URL
        do {
            candidate = try BundleLauncher.makeBundle(binary: source, at: candidateBundle,
                                                      baseBundle: AppEnvironment.appBundleURL, version: newVersion)
        } catch {
            await rollback(to: previous, reason: "cannot stage bundle: \(error.localizedDescription)", bad: target)
            report.outcome = "rolled-back"; report.detail = "staging failed"
            return report
        }

        // Health-check the candidate on an ephemeral port within the configured timeout.
        update { $0.state = "health-check" }
        guard await healthCheck(candidate, timeout: cfg.healthCheckTimeoutSeconds) else {
            try? FileManager.default.removeItem(at: candidateBundle)
            await rollback(to: previous, reason: "candidate failed health-check within \(Int(cfg.healthCheckTimeoutSeconds))s", bad: target)
            report.outcome = "rolled-back"; report.detail = "health-check failed"
            return report
        }

        // Atomic swap of bin/current (symlink rename is atomic on APFS).
        let tmpLink = AppPaths.binDir.appendingPathComponent("current.tmp")
        try? FileManager.default.removeItem(at: tmpLink)
        do {
            try FileManager.default.createSymbolicLink(at: tmpLink, withDestinationURL: candidate)
            guard rename(tmpLink.path, AppPaths.currentBinaryLink.path) == 0 else { throw NSError(domain: "rename", code: Int(errno)) }
            var meta: [String: String] = ["commit": target, "path": candidate.path, "baseBundleCommit": AppEnvironment.bundledCommit]
            if let v = newVersion { meta["version"] = v }
            try JSONSerialization.data(withJSONObject: meta).write(to: AppPaths.currentBinaryMeta, options: .atomic)
        } catch {
            await rollback(to: previous, reason: "atomic swap failed: \(error.localizedDescription)", bad: target)
            report.outcome = "rolled-back"; report.detail = "swap failed"
            return report
        }

        update { $0.state = "restarting"; $0.pendingCodeCommit = nil }
        report.outcome = "rebuilt"
        report.detail = "built \(target.prefix(8)); blue/green restart in progress"
        update { $0.lastReport = report }
        let ok = await app.performBlueGreenRestart(binary: candidate, commit: target, version: newVersion)
        if !ok {
            await rollback(to: previous, reason: "new instance did not take over", bad: target)
            restorePreviousBinaryLink()
            report.outcome = "rolled-back"
            report.detail = "hand-off failed; staying on \(AppEnvironment.runningCommit.prefix(8))"
        }
        return report
    }

    /// Launches the candidate in `--health-check` mode on an ephemeral port and probes /health.
    private func healthCheck(_ binary: URL, timeout: TimeInterval) async -> Bool {
        let port = Int.random(in: 20_000...40_000)
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--health-check", "--port", String(port)]
        var env = ProcessInfo.processInfo.environment
        if let b = AppEnvironment.appBundleURL { env["LOCALLLM_APP_BUNDLE"] = b.path }
        if let r = AppEnvironment.resourcesURL { env["LOCALLLM_RESOURCES"] = r.path }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        defer { if p.isRunning { p.terminate() } }
        let deadline = Date().addingTimeInterval(timeout)
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        while Date() < deadline {
            if let (data, resp) = try? await URLSession.shared.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               JSON.object(data)?["status"] as? String == "ok" {
                Log.info("git", "Candidate \(binary.lastPathComponent) passed health-check")
                return true
            }
            if !p.isRunning { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        Log.error("git", "Candidate \(binary.lastPathComponent) failed health-check")
        return false
    }

    private func rollback(to previous: String, reason: String, bad: String) async {
        // ORIG_HEAD is set by the fast-forward pull to the pre-pull commit; verify before using it.
        let orig = await rev("ORIG_HEAD")
        let target = orig == previous ? "ORIG_HEAD" : previous
        let r = await git(["reset", "--hard", target])
        Log.error("git", "Rollback to \(previous.prefix(8)) (\(target)): \(reason) -> \(r.ok ? "ok" : r.combined)")
        app.tracker.incident("auto-update-rollback", "\(bad.prefix(12)) rejected: \(reason); reset --hard \(target) (\(previous.prefix(12)))")
        update { s in
            if !s.badCommits.contains(bad) { s.badCommits.append(bad) }
            if s.badCommits.count > 50 { s.badCommits.removeFirst(s.badCommits.count - 50) }
        }
        await refreshHead()
        _ = await app.reloadConfig(reason: "rollback")
    }

    private func restorePreviousBinaryLink() {
        // If the swap happened but hand-off failed, point bin/current back at the running binary
        // (or remove it when running the bundled binary).
        let running = AppEnvironment.executableURL
        if running.path.hasPrefix(AppPaths.binDir.path) {
            try? FileManager.default.removeItem(at: AppPaths.currentBinaryLink)
            try? FileManager.default.createSymbolicLink(at: AppPaths.currentBinaryLink, withDestinationURL: running)
        } else {
            try? FileManager.default.removeItem(at: AppPaths.currentBinaryLink)
            try? FileManager.default.removeItem(at: AppPaths.currentBinaryMeta)
        }
    }

    private func finish(failed reason: String, _ r: SyncReport) -> SyncReport {
        var report = r
        report.outcome = "failed"
        report.detail = reason
        app.tracker.incident("git-sync-failed", reason)
        return finish(report)
    }

    @discardableResult
    private func finish(_ r: SyncReport) -> SyncReport {
        var report = r
        report.finishedAt = Date()
        update { s in
            s.state = "idle"
            s.lastSyncAt = Date()
            s.lastReport = report
        }
        Log.info("git", "Sync [\(report.trigger)] -> \(report.outcome): \(report.detail)")
        return report
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
}
