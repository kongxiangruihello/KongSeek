import AppKit
import Security
import KongSeekCore

/// Updates KongSeek from its own source folder (adapted from KongFetch 4.3/4.7).
///
/// The app is signed with a certificate that exists only on this Mac, so updates are
/// built here: fetch GitHub, bring the source folder to origin/main, run
/// scripts/build-app.sh --test, check that the new app carries the same signing
/// identity (so permissions survive), back up the running app, then a small helper
/// script swaps the bundles after KongSeek quits and opens the new one.
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case updating(String)
        case failed(String)
    }

    struct State: Equatable {
        var phase: Phase = .idle
        /// Commit subjects on GitHub not in this build (known only for builds that recorded their commit).
        var pending: [String] = []
        /// Version on GitHub when it is newer than the running one.
        var remoteVersion: String?
        /// CHANGELOG sections newer than the running version.
        var notes: [ReleaseNotes.Section] = []
        var lastCheck: Date?
        var sourceRoot: String?
        var backups: [String] = []

        var hasUpdate: Bool { remoteVersion != nil || !pending.isEmpty }
        var isBusy: Bool {
            switch phase {
            case .checking, .updating: return true
            default: return false
            }
        }
    }

    private(set) var state = State()
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "KongSeek.updater", qos: .utility)
    private let supportDirectory: URL
    private var timer: Timer?
    var logURL: URL { supportDirectory.appendingPathComponent("update.log") }
    private var backupsURL: URL { supportDirectory.appendingPathComponent("Backups", isDirectory: true) }

    init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
        state.sourceRoot = Self.locateSourceRoot()
        state.backups = listBackups()
    }

    // MARK: Facts about this build

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    /// Recorded by the build script when the source folder had no local changes.
    static var installedCommit: String? { Bundle.main.object(forInfoDictionaryKey: "KSSourceCommit") as? String }

    /// The repository this copy was built from (recorded by the build script), or the usual place.
    static func locateSourceRoot() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let recorded = Bundle.main.object(forInfoDictionaryKey: "KSSourceRoot") as? String { candidates.append(recorded) }
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Developer/kongseek").path)
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Developer/KongSeek").path)
        return candidates.first { fm.fileExists(atPath: $0 + "/.git") && fm.fileExists(atPath: $0 + "/scripts/build-app.sh") }
    }

    /// How the running app is signed, which decides whether permissions survive updates.
    static func signingDescription() -> String {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return "无法读取"
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return "未签名" }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return "ad hoc（每次更新后需重新授权）" }
        if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let first = certificates.first, let name = SecCertificateCopySubjectSummary(first) as String? {
            return "证书：\(name)"
        }
        return "已签名"
    }

    // MARK: Checking

    /// Checks shortly after launch and then every six hours.
    func startAutomaticChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check() }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAutomaticChecks() {
        timer?.invalidate()
        timer = nil
    }

    func check() {
        guard !state.isBusy else { return }
        state.sourceRoot = Self.locateSourceRoot()
        guard let root = state.sourceRoot else {
            set { $0.phase = .failed("找不到 KongSeek 的源码文件夹（应在 ~/Developer/kongseek）") }
            return
        }
        set { $0.phase = .checking }
        queue.async { [weak self] in
            guard let self else { return }
            let fetch = self.git(["fetch", "--quiet", "origin", "main"], root)
            guard fetch.status == 0 else {
                self.set { $0.phase = .failed("连不上 GitHub，稍后再试（详情见更新日志）"); $0.lastCheck = Date() }
                return
            }
            let running = Self.version
            let remotePlist = self.git(["show", "origin/main:Resources/Info.plist"], root, logOutput: false)
            let remote = ReleaseNotes.version(inInfoPlist: Data(remotePlist.output.utf8))
            let changelog = self.git(["show", "origin/main:CHANGELOG.md"], root, logOutput: false).output
            var subjects: [String] = []
            if let commit = Self.installedCommit, self.git(["cat-file", "-e", commit], root).status == 0 {
                subjects = self.git(["log", "--format=%s", "\(commit)..origin/main"], root).output
                    .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            }
            let newer = remote.flatMap { ReleaseNotes.isNewer($0, than: running) ? $0 : nil }
            let notes = ReleaseNotes.sections(in: changelog, newerThan: running)
            self.log("检查：本机 \(running)，GitHub \(remote ?? "?")，新提交 \(subjects.count) 个")
            self.set {
                $0.phase = .idle
                $0.remoteVersion = newer
                $0.pending = subjects
                $0.notes = notes
                $0.lastCheck = Date()
            }
        }
    }

    // MARK: Updating

    /// Fetches (unless `fromLocalSource`), builds with tests, verifies and installs.
    /// KongSeek quits and reopens when it succeeds.
    func update(fromLocalSource: Bool = false) {
        guard !state.isBusy else { return }
        state.sourceRoot = Self.locateSourceRoot()
        guard let root = state.sourceRoot else {
            set { $0.phase = .failed("找不到 KongSeek 的源码文件夹（应在 ~/Developer/kongseek）") }
            return
        }
        set { $0.phase = .updating(fromLocalSource ? "正在用源码文件夹中的代码编译…" : "正在获取更新…") }
        queue.async { [weak self] in
            guard let self else { return }
            self.log("==== \(fromLocalSource ? "从本地源码重新构建" : "更新") 开始 \(Date())")
            do {
                if !fromLocalSource {
                    try self.step(self.git(["fetch", "--quiet", "origin", "main"], root), "无法连接 GitHub")
                    try self.bringSourceUpToDate(root)
                }
                self.set { $0.phase = .updating("正在测试并编译（约一两分钟）…") }
                try self.step(self.run("/bin/bash", ["scripts/build-app.sh", "--test"], root), "测试或编译失败（详情见 build/build.log）")

                let built = URL(fileURLWithPath: root).appendingPathComponent("build/KongSeek.app")
                self.set { $0.phase = .updating("正在校验签名…") }
                try self.verifySignature(of: built)

                self.set { $0.phase = .updating("正在备份当前版本…") }
                try self.backupRunningApp()

                self.set { $0.phase = .updating("正在安装，KongSeek 将重新打开…") }
                try self.installAndRelaunch(built)
            } catch {
                let message = (error as? UpdateError)?.message ?? error.localizedDescription
                self.log("失败：\(message)")
                self.set { $0.phase = .failed(message) }
            }
        }
    }

    /// Moves the source folder to origin/main. Local changes are allowed only where
    /// they already equal origin/main (files copied in from a newer checkout);
    /// anything else stops the update rather than being overwritten.
    private func bringSourceUpToDate(_ root: String) throws {
        if git(["merge-base", "--is-ancestor", "HEAD", "origin/main"], root).status != 0 {
            throw UpdateError("源码文件夹里有 GitHub 上没有的提交，为避免丢失，已停止更新。")
        }
        let changed = git(["diff", "--name-only", "HEAD"], root).output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        var conflicts: [String] = []
        for path in changed where git(["diff", "--quiet", "origin/main", "--", path], root).status != 0 {
            conflicts.append(path)
        }
        let untracked = git(["ls-files", "--others", "--exclude-standard"], root, logOutput: false).output
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        for path in untracked {
            let upstream = git(["rev-parse", "--verify", "--quiet", "origin/main:\(path)"], root, logOutput: false)
            guard upstream.status == 0 else { continue } // not in the repository: left alone
            let local = git(["hash-object", "--", path], root, logOutput: false)
            if local.output.trimmingCharacters(in: .whitespacesAndNewlines) != upstream.output.trimmingCharacters(in: .whitespacesAndNewlines) {
                conflicts.append(path)
            }
        }
        guard conflicts.isEmpty else {
            throw UpdateError("源码文件夹里这些文件有本地修改，为避免覆盖，已停止更新：" + conflicts.prefix(5).joined(separator: "、"))
        }
        try step(git(["reset", "--hard", "--quiet", "origin/main"], root), "无法更新源码文件夹")
    }

    /// Reinstalls the most recent backup.
    func rollback() {
        guard let latest = listBackups().first else { return }
        let url = backupsURL.appendingPathComponent(latest)
        set { $0.phase = .updating("正在回退到 \(latest)…") }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.installAndRelaunch(url)
            } catch {
                self.set { $0.phase = .failed("回退失败：\(error.localizedDescription)") }
            }
        }
    }

    func clearFailure() {
        if case .failed = state.phase { set { $0.phase = .idle } }
    }

    // MARK: Steps (on `queue`)

    private struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func step(_ result: (status: Int32, output: String), _ failure: String) throws {
        guard result.status == 0 else {
            let detail = result.output.split(separator: "\n").suffix(3).joined(separator: " ")
            throw UpdateError(failure + (detail.isEmpty ? "" : "：" + detail))
        }
    }

    /// The new app must satisfy the running app's designated requirement, so macOS keeps
    /// treating it as the same app (Input Monitoring, Accessibility, folder access stay granted).
    private func verifySignature(of app: URL) throws {
        var current: SecStaticCode?
        var candidate: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &current) == errSecSuccess, let current,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw UpdateError("无法读取新版本的签名")
        }
        if Self.signingDescription().hasPrefix("ad hoc") {
            log("当前版本为 ad hoc 签名，跳过身份比对；更新后需重新授权。")
            guard SecStaticCodeCheckValidity(candidate, [], nil) == errSecSuccess else { throw UpdateError("新版本签名无效") }
            return
        }
        guard SecCodeCopyDesignatedRequirement(current, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("无法读取当前版本的签名要求")
        }
        let status = SecStaticCodeCheckValidity(candidate, [], requirement)
        guard status == errSecSuccess else {
            throw UpdateError("新版本的签名与当前版本不一致（\(status)），为保住已授予的权限，已停止安装。请确认钥匙串里的签名证书还在。")
        }
    }

    private func backupRunningApp() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        let target = backupsURL.appendingPathComponent(Self.runningBackupName)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try step(run("/usr/bin/ditto", [Bundle.main.bundleURL.path, target.path], "/"), "备份失败")
        // Keep the two most recent earlier versions (plus the one just backed up).
        for old in listBackups().dropFirst(2) { try? fm.removeItem(at: backupsURL.appendingPathComponent(old)) }
        let backups = listBackups()
        set { $0.backups = backups }
    }

    /// Writes a helper that waits for KongSeek to quit, swaps the bundle (restoring the
    /// old one if copying fails) and opens the result. Then quits KongSeek.
    private func installAndRelaunch(_ newApp: URL) throws {
        let target = Bundle.main.bundleURL.path.hasSuffix(".app") ? Bundle.main.bundleURL.path : "/Applications/KongSeek.app"
        let script = """
        #!/bin/bash
        pid="$1"; new="$2"; target="$3"; log="$4"
        for i in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
        {
          echo "安装 $new -> $target"
          rm -rf "$target.updating-old"
          if mv "$target" "$target.updating-old" && ditto "$new" "$target"; then
            rm -rf "$target.updating-old"
            echo "安装完成"
          else
            echo "安装失败，恢复原版本"
            rm -rf "$target"
            mv "$target.updating-old" "$target"
          fi
        } >> "$log" 2>&1
        open "$target"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("kongseek-install-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target, logURL.path]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        log("已启动安装程序，KongSeek 即将退出。")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// Backup name of the running copy, e.g. "KongSeek-0.9.0-12.app".
    private static var runningBackupName: String { "KongSeek-\(version)-\(build).app" }

    /// Backups other than the running version, newest build first.
    private func listBackups() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: backupsURL.path))?.filter { $0.hasSuffix(".app") } ?? []
        func build(_ name: String) -> Int { Int(name.dropLast(4).split(separator: "-").last ?? "") ?? 0 }
        func modified(_ name: String) -> Date {
            (try? fm.attributesOfItem(atPath: backupsURL.appendingPathComponent(name).path)[.modificationDate] as? Date) ?? .distantPast
        }
        return names.filter { $0 != Self.runningBackupName }.sorted { a, b in
            build(a) != build(b) ? build(a) > build(b) : modified(a) > modified(b)
        }
    }

    // MARK: Processes

    private func git(_ arguments: [String], _ root: String, logOutput: Bool = true) -> (status: Int32, output: String) {
        // Give up on a transfer slower than 1 KB/s for 20 seconds, and on any git command after 2 minutes.
        run("/usr/bin/git", ["-C", root, "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=20"] + arguments, root,
            timeout: 120, logOutput: logOutput)
    }

    /// Runs a command to completion, appending it (and its output) to the update log.
    /// A command that runs longer than `timeout` seconds is stopped.
    private func run(_ executable: String, _ arguments: [String], _ directory: String,
                     timeout: TimeInterval = 1200, logOutput: Bool = true) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        environment["GIT_TERMINAL_PROMPT"] = "0" // never wait for a password prompt
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            log("$ \(executable) \(arguments.joined(separator: " "))\n无法运行：\(error.localizedDescription)")
            return (-1, error.localizedDescription)
        }
        var timedOut = false
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut = true
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        var output = String(decoding: data, as: UTF8.self)
        if timedOut { output += "\n超过 \(Int(timeout)) 秒未完成，已停止。" }
        let shown = logOutput ? output : "（输出 \(data.count) 字节）\n"
        log("$ \(executable) \(arguments.joined(separator: " "))\n\(shown)(退出码 \(process.terminationStatus))")
        return (timedOut ? -2 : process.terminationStatus, output)
    }

    private func log(_ text: String) {
        let line = text.hasSuffix("\n") ? text : text + "\n"
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    private func set(_ change: @escaping (inout State) -> Void) {
        DispatchQueue.main.async {
            var next = self.state
            change(&next)
            if next != self.state {
                self.state = next
                self.onChange?()
            }
        }
    }
}
