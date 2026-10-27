import AppKit
import UniformTypeIdentifiers
import KongSeekCore

/// Export and import of settings and snippets (设置 › 通用). Adapted from KongFetch 4.7.
enum SettingsTransfer {
    private static var fileType: UTType { UTType(filenameExtension: SettingsArchive.fileExtension) ?? .propertyList }
    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.kongxiangrui.KongSeek" }

    /// KongSeek's own settings (not the global ones every app sees).
    static var currentDefaults: [String: Any] {
        UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
    }

    static func exportSettings(library: SnippetLibrary) {
        let panel = NSSavePanel()
        panel.title = "导出 KongSeek 设置"
        panel.nameFieldStringValue = "KongSeek 设置 \(dateStamp()).\(SettingsArchive.fileExtension)"
        panel.allowedContentTypes = [fileType]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let archive = SettingsArchive(defaults: currentDefaults, snippets: library.snippets,
                                          appVersion: Updater.version, home: NSHomeDirectory())
            try archive.encoded().write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func importSettings(library: SnippetLibrary) {
        let panel = NSOpenPanel()
        panel.title = "导入 KongSeek 设置"
        panel.prompt = "导入"
        panel.allowedContentTypes = [fileType]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let archive: SettingsArchive
        do {
            archive = try SettingsArchive.decode(Data(contentsOf: url))
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "导入这些设置？"
        alert.informativeText = "来自 KongSeek \(archive.appVersion)，导出于 \(archive.created.formatted(date: .abbreviated, time: .shortened))："
            + "\(archive.defaults.count) 项设置、\(archive.snippets.count) 个片段。\n\n"
            + "当前的设置和片段会被替换（剪贴板历史、最近打开和索引不受影响），之后 KongSeek 会重新打开；索引的文件夹若有变化，会重建索引。"
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let defaults = UserDefaults.standard
        let incoming = archive.restoredDefaults(home: NSHomeDirectory())
        for key in SettingsArchive.transferableKeys where incoming[key] == nil {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in incoming { defaults.set(value, forKey: key) }
        defaults.synchronize()
        library.replaceAll(archive.snippets)
        relaunch()
    }

    /// Starts a fresh copy of KongSeek a second after this one quits.
    static func relaunch() {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? helper.run()
        NSApp.terminate(nil)
    }

    static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

/// A zip of what helps find out why something does not work: a status report, the
/// update and build logs, recent crash reports and the settings. Clipboard history,
/// snippet text and recently opened items stay out.
enum DiagnosticsBundle {
    static func export(report: String, updateLog: URL, sourceRoot: String?) {
        let panel = NSSavePanel()
        panel.title = "导出诊断包"
        panel.nameFieldStringValue = "KongSeek 诊断 \(SettingsTransfer.dateStamp()).zip"
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let target = panel.url else { return }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("kongseek-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let folder = work.appendingPathComponent("KongSeek 诊断", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try report.write(to: folder.appendingPathComponent("报告.txt"), atomically: true, encoding: .utf8)
            copyTail(of: updateLog, to: folder.appendingPathComponent("update.log"))
            if let sourceRoot {
                copyTail(of: URL(fileURLWithPath: sourceRoot).appendingPathComponent("build/build.log"),
                         to: folder.appendingPathComponent("build.log"))
            }
            let settings = SettingsArchive(defaults: SettingsTransfer.currentDefaults, snippets: [],
                                           appVersion: Updater.version, home: NSHomeDirectory())
            try settings.encoded().write(to: folder.appendingPathComponent("设置（不含片段）.plist"))
            let reports = recentCrashReports(limit: 5)
            if !reports.isEmpty {
                let crashes = folder.appendingPathComponent("崩溃报告", isDirectory: true)
                try fm.createDirectory(at: crashes, withIntermediateDirectories: true)
                for url in reports { try? fm.copyItem(at: url, to: crashes.appendingPathComponent(url.lastPathComponent)) }
            }
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            zip.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, target.path]
            try zip.run()
            zip.waitUntilExit()
            guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// The last half megabyte of a log.
    private static func copyTail(of source: URL, to destination: URL) {
        guard let handle = try? FileHandle(forReadingFrom: source) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 512_000 ? size - 512_000 : 0
        try? handle.seek(toOffset: start)
        if let data = try? handle.readToEnd() { try? data.write(to: destination) }
    }

    private static func recentCrashReports(limit: Int) -> [URL] {
        let fm = FileManager.default
        let folders = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
                       URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]
        var found: [(URL, Date)] = []
        for folder in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasPrefix("KongSeek") {
                let url = folder.appendingPathComponent(name)
                let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                found.append((url, date))
            }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
