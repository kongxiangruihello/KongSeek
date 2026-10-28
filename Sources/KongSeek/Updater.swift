import AppKit
import Security
import CFNetwork
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
        /// The update in progress (or just ended), for the progress window.
        var progress: Progress?

        var hasUpdate: Bool { remoteVersion != nil || !pending.isEmpty }
        var isBusy: Bool {
            switch phase {
            case .checking, .updating: return true
            default: return false
            }
        }
    }

    /// The steps of an update, shown in the progress window.
    enum Step: Int, CaseIterable, Equatable {
        case fetch, test, compile, verify, backup, install

        var title: String {
            switch self {
            case .fetch: return "从 GitHub 获取新代码"
            case .test: return "编译并运行测试"
            case .compile: return "编译新版本"
            case .verify: return "校验签名"
            case .backup: return "备份当前版本"
            case .install: return "安装并重新打开"
            }
        }
    }

    struct Progress: Equatable {
        var title: String
        var steps: [Step]
        var current: Step
        /// Whole update, 0…1.
        var fraction: Double = 0
        var detail: String = ""
        var started = Date()
        /// Set when the update stopped; the installed version is unchanged.
        var failure: String?
        var finished = false
    }

    private(set) var state = State()
    var onChange: (() -> Void)?
    /// Called on main when an update starts, so the progress window can appear.
    var onUpdateStarted: (() -> Void)?

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

    // MARK: Network

    /// The proxy typed in Settings, else the system's HTTPS/HTTP/SOCKS proxy; nil for a direct connection.
    static var proxy: String? {
        if let typed = ProxySettings.normalized(Preferences.updateProxy) { return typed }
        return systemProxy
    }

    static var systemProxy: String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        return ProxySettings.gitProxy(fromSystem: settings)
    }

    /// Explains a failed fetch in words a user can act on.
    private static func fetchFailure(_ output: String) -> String {
        guard ProxySettings.isConnectionFailure(output) else { return "从 GitHub 获取更新失败（详情见更新日志）" }
        if let proxy {
            return "通过代理 \(proxy) 仍连不上 GitHub。请确认代理软件正在运行、端口正确。"
        }
        return "这台 Mac 直连不上 GitHub（中国大陆常见）。如果你用代理软件，请打开它的“系统代理”，或在下面填写代理地址；"
            + "否则请在源码更新后点“用本地源码重新构建”。"
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
            let fetch = self.fetch(root)
            guard fetch.status == 0 else {
                let message = Self.fetchFailure(fetch.output)
                self.set { $0.phase = .failed(message); $0.lastCheck = Date() }
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
        let steps: [Step] = fromLocalSource ? [.test, .compile, .verify, .backup, .install] : Step.allCases
        let title = fromLocalSource ? "用本地源码重新构建 KongSeek" : "更新 KongSeek" + (state.remoteVersion.map { " 到 \($0)" } ?? "")
        set {
            $0.phase = .updating(fromLocalSource ? "正在用源码文件夹中的代码编译…" : "正在获取更新…")
            $0.progress = Progress(title: title, steps: steps, current: steps[0], detail: fromLocalSource ? "准备中…" : "正在连接 GitHub…")
        }
        onUpdateStarted?()
        queue.async { [weak self] in
            guard let self else { return }
            self.log("==== \(fromLocalSource ? "从本地源码重新构建" : "更新") 开始 \(Date())")
            // Share of the whole bar before the build starts.
            let buildStart = fromLocalSource ? 0.0 : 0.08
            do {
                if !fromLocalSource {
                    let fetch = self.fetch(root)
                    guard fetch.status == 0 else { throw UpdateError(Self.fetchFailure(fetch.output)) }
                    self.report(.fetch, fraction: 0.05, "正在更新源码文件夹…")
                    try self.bringSourceUpToDate(root)
                }
                self.set { $0.phase = .updating("正在测试并编译（约一两分钟）…") }
                self.report(.test, fraction: buildStart, "正在编译测试…")
                var build = BuildLogProgress(expectedTests: UserDefaults.standard.integer(forKey: "lastTestCount").nonZero ?? 120)
                var shown = (detail: "", fraction: -1.0)
                let result = self.run("/bin/bash", ["scripts/build-app.sh", "--test"], root) { line in
                    build.consume(line)
                    let fraction = buildStart + (0.9 - buildStart) * build.overall
                    guard build.detail != shown.detail || fraction - shown.fraction >= 0.01 else { return }
                    shown = (build.detail, fraction)
                    self.report(build.stage >= .compiling ? .compile : .test, fraction: fraction, build.detail)
                }
                if let total = build.executedTests, total > 0 { UserDefaults.standard.set(total, forKey: "lastTestCount") }
                guard result.status == 0 else {
                    if !build.failedTests.isEmpty || build.testsCrashed {
                        var message = build.failedTests.isEmpty ? "测试程序运行中崩溃" : "有 \(build.failedTests.count) 项测试未通过（\(build.failedTests.prefix(3).joined(separator: "、"))）"
                        message += "，已停止；当前安装的版本没有改动。"
                        if let first = build.testFailures.first { message += "\n" + first }
                        throw UpdateError(message)
                    }
                    if let first = build.compileErrors.first {
                        throw UpdateError("编译失败，已停止；当前安装的版本没有改动。\n" + first
                            + (build.compileErrors.count > 1 ? "（另有 \(build.compileErrors.count - 1) 处）" : ""))
                    }
                    throw UpdateError("测试或编译失败（详情见构建日志），已停止；当前安装的版本没有改动。")
                }

                let built = URL(fileURLWithPath: root).appendingPathComponent("build/KongSeek.app")
                self.set { $0.phase = .updating("正在校验签名…") }
                self.report(.verify, fraction: 0.92, "确认新版本与当前版本的签名一致，以保留已授予的权限…")
                try self.verifySignature(of: built)

                self.set { $0.phase = .updating("正在备份当前版本…") }
                self.report(.backup, fraction: 0.95, "备份 KongSeek \(Self.version)，以便需要时回退…")
                try self.backupRunningApp()

                self.set { $0.phase = .updating("正在安装，KongSeek 将重新打开…") }
                self.report(.install, fraction: 1, "安装完成，KongSeek 将在几秒内重新打开…")
                self.set { $0.progress?.finished = true }
                UserDefaults.standard.set(Self.version, forKey: "updatedFrom")
                try self.installAndRelaunch(built)
            } catch {
                let message = (error as? UpdateError)?.message ?? error.localizedDescription
                self.log("失败：\(message)")
                UserDefaults.standard.removeObject(forKey: "updatedFrom")
                self.set {
                    $0.phase = .failed(message)
                    $0.progress?.failure = message
                }
            }
        }
    }

    /// Moves the progress window to `step`.
    private func report(_ step: Step, fraction: Double, _ detail: String) {
        set {
            guard var progress = $0.progress else { return }
            progress.current = step
            progress.fraction = max(progress.fraction, fraction)
            progress.detail = detail
            $0.progress = progress
        }
    }

    func dismissProgress() {
        guard state.progress != nil, !state.isBusy else { return }
        set { $0.progress = nil }
    }

    /// Moves the source folder to origin/main. A locally changed file is fine when
    /// its content equals that file in some published commit (copied in from a
    /// newer checkout, as the old update route did); anything else is a real edit,
    /// and the update stops rather than overwrite it. Files the repository has
    /// never contained are left alone.
    private func bringSourceUpToDate(_ root: String) throws {
        if git(["merge-base", "--is-ancestor", "HEAD", "origin/main"], root).status != 0 {
            throw UpdateError("源码文件夹里有 GitHub 上没有的提交，为避免丢失，已停止更新。")
        }
        func lines(_ result: (status: Int32, output: String)) -> [String] {
            result.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        let changed = lines(git(["diff", "--name-only", "HEAD"], root, logOutput: false))
        let untracked = lines(git(["ls-files", "--others", "--exclude-standard"], root, logOutput: false))
        let fm = FileManager.default
        let local = Array(Set(changed + untracked)).sorted().filter { fm.fileExists(atPath: root + "/" + $0) }
        if !local.isEmpty {
            let hashes = lines(git(["hash-object", "--"] + local, root, logOutput: false))
            guard hashes.count == local.count else { throw UpdateError("无法读取源码文件夹中的文件") }
            // Every version of every file in the last 200 published commits.
            var published: [String: Set<String>] = [:]
            for commit in lines(git(["rev-list", "--max-count=200", "origin/main"], root, logOutput: false)) {
                for entry in lines(git(["ls-tree", "-r", commit], root, logOutput: false)) {
                    // "<mode> blob <hash>\t<path>"
                    let parts = entry.split(separator: "\t", maxSplits: 1)
                    guard parts.count == 2, let hash = parts[0].split(separator: " ").last else { continue }
                    published[String(parts[1]), default: []].insert(String(hash))
                }
            }
            let tracked = Set(changed)
            var conflicts: [String] = []
            for (path, hash) in zip(local, hashes) {
                if let versions = published[path] {
                    if !versions.contains(hash) { conflicts.append(path) }
                } else if tracked.contains(path) {
                    conflicts.append(path)
                }
            }
            guard conflicts.isEmpty else {
                throw UpdateError("源码文件夹里这些文件有本地修改，为避免覆盖，已停止更新：" + conflicts.prefix(5).joined(separator: "、"))
            }
            log("本地有 \(local.count) 个文件与已发布版本相同，可安全更新。")
        }
        try step(git(["reset", "--hard", "--quiet", "origin/main"], root), "无法更新源码文件夹")
    }

    /// Reinstalls the most recent backup.
    func rollback() {
        guard let latest = listBackups().first else { return }
        let url = backupsURL.appendingPathComponent(latest)
        set {
            $0.phase = .updating("正在回退到 \(latest)…")
            $0.progress = Progress(title: "回退到 " + latest.replacingOccurrences(of: ".app", with: ""), steps: [.install], current: .install,
                                   fraction: 0.5, detail: "正在换回上一版，KongSeek 将重新打开…")
        }
        onUpdateStarted?()
        queue.async { [weak self] in
            guard let self else { return }
            do {
                UserDefaults.standard.set(Self.version, forKey: "updatedFrom")
                try self.installAndRelaunch(url)
            } catch {
                UserDefaults.standard.removeObject(forKey: "updatedFrom")
                self.set {
                    $0.phase = .failed("回退失败：\(error.localizedDescription)")
                    $0.progress?.failure = "回退失败：\(error.localizedDescription)"
                }
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
        // A moment for the progress window to show "完成" before quitting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
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

    /// `git fetch origin main`, through the proxy when there is one. Stopped after 45
    /// seconds: an unreachable GitHub otherwise takes 75 seconds or more to fail.
    private func fetch(_ root: String) -> (status: Int32, output: String) {
        let proxy = Self.proxy
        log("连接 GitHub：" + (proxy.map { "经代理 \($0)" } ?? "直连"))
        let proxyOptions = proxy.map { ["-c", "http.proxy=\($0)"] } ?? []
        return git(proxyOptions + ["fetch", "--quiet", "origin", "main"], root, timeout: 45)
    }

    func git(_ arguments: [String], _ root: String, timeout: TimeInterval = 120, logOutput: Bool = true) -> (status: Int32, output: String) {
        // Give up on a transfer slower than 1 KB/s for 20 seconds.
        run("/usr/bin/git", ["-C", root, "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=20"] + arguments, root,
            timeout: timeout, logOutput: logOutput)
    }

    /// Runs a command to completion, appending it (and its output) to the update log.
    /// A command that runs longer than `timeout` seconds is stopped.
    func run(_ executable: String, _ arguments: [String], _ directory: String,
                     timeout: TimeInterval = 1200, logOutput: Bool = true,
                     onLine: ((String) -> Void)? = nil) -> (status: Int32, output: String) {
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
        // Read as output arrives, handing complete lines (split at \n or \r) to `onLine`.
        var data = Data()
        var pending = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            guard let onLine else { continue }
            pending.append(chunk)
            while let cut = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                onLine(String(decoding: pending[pending.startIndex..<cut], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...cut)
            }
        }
        if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        process.waitUntilExit()
        watchdog.cancel()
        var output = String(decoding: data, as: UTF8.self)
        if timedOut { output += "\n超过 \(Int(timeout)) 秒未完成，已停止。" }
        let shown = logOutput ? output : "（输出 \(data.count) 字节）\n"
        log("$ \(executable) \(arguments.joined(separator: " "))\n\(shown)(退出码 \(process.terminationStatus))")
        return (timedOut ? -2 : process.terminationStatus, output)
    }

    func log(_ text: String) {
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

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
