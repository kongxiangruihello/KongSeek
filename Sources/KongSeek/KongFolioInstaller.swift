import AppKit
import KongSeekCore

/// Installs or updates KongFolio from GitHub on this Mac (0.25), the way KongSeek updates
/// itself: the source goes to ~/Developer/kongfolio, KongFolio's own scripts/build.sh
/// builds it, and the app in 应用程序 is replaced (the previous one is kept as a backup).
final class KongFolioInstaller {
    static let shared = KongFolioInstaller()
    static let repository = "https://github.com/kongxiangruihello/KongFolio.git"

    enum Phase: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    /// For running commands and writing the update log (set by the app delegate).
    var updater: Updater?
    private(set) var phase: Phase = .idle
    var onChange: (() -> Void)?
    private let queue = DispatchQueue(label: "KongSeek.kongfolio-installer", qos: .utility)

    var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    static var sourceRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/kongfolio").path
    }

    private static var backupsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KongSeek/Backups", isDirectory: true)
    }

    /// The version in the downloaded source, if it has been downloaded.
    static var sourceVersion: String? {
        let plist = URL(fileURLWithPath: sourceRoot).appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// Where KongFolio is installed: the copy in 应用程序 when there is one.
    static var installTarget: String {
        let fm = FileManager.default
        let candidates = ["/Applications/KongFolio.app",
                          fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/KongFolio.app").path]
        if let existing = candidates.first(where: { fm.fileExists(atPath: $0) }) { return existing }
        if let registered = KongFolio.appURL?.path, registered.contains("/Applications/") { return registered }
        return candidates[0]
    }

    func install() {
        guard !isBusy, let updater else { return }
        set(.working("正在从 GitHub 获取 KongFolio 源码…"))
        updater.log("\n==== 安装 / 更新 KongFolio \(Date()) ====")
        queue.async {
            do {
                let message = try self.perform(updater)
                self.set(.done(message))
            } catch let failure as Failure {
                updater.log("KongFolio：\(failure.message)")
                self.set(.failed(failure.message))
            } catch {
                self.set(.failed(error.localizedDescription))
            }
        }
    }

    private func step(_ result: (status: Int32, output: String), _ failure: String) throws {
        guard result.status == 0 else {
            let detail = result.output.split(separator: "\n").suffix(2).joined(separator: " ")
            throw Failure(failure + (detail.isEmpty ? "" : "：" + detail))
        }
    }

    private func perform(_ updater: Updater) throws -> String {
        let fm = FileManager.default
        let root = Self.sourceRoot
        let proxy = Updater.proxy.map { ["-c", "http.proxy=\($0)"] } ?? []
        let slow = ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=30"]
        if !fm.fileExists(atPath: root + "/.git") {
            guard !fm.fileExists(atPath: root) else {
                throw Failure("~/Developer/kongfolio 已存在但不是从 GitHub 下载的源码文件夹，请把它移走或改名后再试。")
            }
            let developer = (root as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: developer, withIntermediateDirectories: true)
            try step(updater.run("/usr/bin/git", slow + proxy + ["clone", "--quiet", Self.repository, root], developer, timeout: 900),
                     "下载 KongFolio 源码失败（请检查网络或在上面填写代理）")
        } else {
            try step(updater.git(slow + proxy + ["fetch", "--quiet", "origin", "main"], root, timeout: 300),
                     "从 GitHub 获取 KongFolio 更新失败（请检查网络或在上面填写代理）")
            let ahead = updater.git(["rev-list", "--count", "origin/main..HEAD"], root).output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ahead == "0" else { throw Failure("~/Developer/kongfolio 里有 GitHub 上没有的提交，为免丢失，已停止。") }
            let changed = updater.git(["status", "--porcelain", "--untracked-files=no"], root, logOutput: false).output
            guard changed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure("~/Developer/kongfolio 里有改动过的文件，为免覆盖，已停止。")
            }
            try step(updater.git(["reset", "--hard", "--quiet", "origin/main"], root), "无法更新 KongFolio 源码")
        }
        let version = Self.sourceVersion ?? "?"
        set(.working("正在编译 KongFolio \(version)（第一次约需 5–10 分钟）…"))
        var lastLine = ""
        let build = updater.run("/bin/bash", ["scripts/build.sh"], root, timeout: 3600) { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // swift build prints "[123/456] Compiling …".
            guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return }
            let counter = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            guard counter != lastLine, counter.contains("/") else { return }
            lastLine = counter
            self.set(.working("正在编译 KongFolio \(version)：\(counter)"))
        }
        try step(build, "编译 KongFolio 失败（详情见更新日志）")
        let developer = URL(fileURLWithPath: root).deletingLastPathComponent()
        let built = developer.appendingPathComponent("KongFolio.app")
        guard fm.fileExists(atPath: built.path) else { throw Failure("编译完成，但没有找到 KongFolio.app") }
        set(.working("正在安装 KongFolio \(version)…"))
        try replaceInstalledApp(with: built, updater: updater)
        // The built copy and the zip next to the source are not needed once installed; leaving the
        // app there would give macOS two KongFolios to choose from.
        try? fm.removeItem(at: built)
        try? fm.removeItem(at: developer.appendingPathComponent("KongFolio-\(version)-macOS.zip"))
        updater.log("KongFolio \(version) 已安装到 \(Self.installTarget)")
        return "已安装 KongFolio \(version)"
    }

    /// Quits a running KongFolio (it asks to save unsaved work), keeps the old app as a
    /// backup, copies the new one in, and opens it again if it was open.
    private func replaceInstalledApp(with built: URL, updater: Updater) throws {
        let fm = FileManager.default
        let target = Self.installTarget
        let running = DispatchQueue.main.sync { NSRunningApplication.runningApplications(withBundleIdentifier: KongFolioLink.bundleIdentifier) }
        if !running.isEmpty {
            set(.working("正在退出 KongFolio（有未保存的修改时它会询问）…"))
            DispatchQueue.main.sync { running.forEach { _ = $0.terminate() } }
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline, running.contains(where: { !$0.isTerminated }) { Thread.sleep(forTimeInterval: 0.5) }
            guard running.allSatisfy(\.isTerminated) else {
                throw Failure("KongFolio 没有退出（可能在等你保存）。请保存并退出 KongFolio 后再点一次“安装 / 更新”。再点时编译会很快。")
            }
        }
        if fm.fileExists(atPath: target) {
            try fm.createDirectory(at: Self.backupsURL, withIntermediateDirectories: true)
            let old = Bundle(path: target)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "old"
            let backup = Self.backupsURL.appendingPathComponent("KongFolio-\(old).app")
            try? fm.removeItem(at: backup)
            try step(updater.run("/usr/bin/ditto", [target, backup.path], "/"), "备份旧版 KongFolio 失败")
            // Keep the two most recent backups.
            let backups = ((try? fm.contentsOfDirectory(atPath: Self.backupsURL.path)) ?? [])
                .filter { $0.hasPrefix("KongFolio-") && $0.hasSuffix(".app") }
                .sorted { modified(Self.backupsURL.appendingPathComponent($0)) > modified(Self.backupsURL.appendingPathComponent($1)) }
            for extra in backups.dropFirst(2) { try? fm.removeItem(at: Self.backupsURL.appendingPathComponent(extra)) }
        }
        let aside = target + ".updating-old"
        try? fm.removeItem(atPath: aside)
        if fm.fileExists(atPath: target) {
            do { try fm.moveItem(atPath: target, toPath: aside) } catch {
                throw Failure("无法替换 \(target)：\(error.localizedDescription)")
            }
        }
        let copy = updater.run("/usr/bin/ditto", [built.path, target], "/")
        if copy.status != 0 {
            try? fm.removeItem(atPath: target)
            try? fm.moveItem(atPath: aside, toPath: target)
            try step(copy, "安装失败，已恢复原来的 KongFolio")
        }
        try? fm.removeItem(atPath: aside)
        if !running.isEmpty {
            DispatchQueue.main.async {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: target), configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    func clearMessage() {
        if case .working = phase { return }
        set(.idle)
    }

    private func set(_ phase: Phase) {
        DispatchQueue.main.async {
            guard self.phase != phase else { return }
            self.phase = phase
            self.onChange?()
        }
    }
}
