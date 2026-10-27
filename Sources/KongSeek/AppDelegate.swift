import AppKit
import ApplicationServices
import ServiceManagement
import KongSeekCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var service: IndexService!
    private var searchWindow: SearchWindowController!
    private var hotKey: HotKey!
    private let doubleTap = DoubleTapMonitor()
    private var settingsWindow: SettingsWindowController?
    private var ocr: OCRService!
    private var clipboardHistory: ClipboardHistory!
    private var clipboardMonitor: ClipboardMonitor!
    private var clipboardPanel: ClipboardPanelController!
    private var clipboardHotKey: HotKey!
    private var lookupHotKey: HotKey!
    private var snippets: SnippetLibrary!
    private var snippetExpansion: SnippetExpansionService!
    private var archives: ArchiveService!
    /// Whether the archive scan has run since the index last became ready.
    private var archivesStarted = false
    private var batchRename: BatchRenameWindowController?
    private var duplicates: DuplicatesWindowController?
    private var space: SpaceWindowController?
    private var scanned: ScannedPDFWindowController?
    private var statusWindow: StatusWindowController?
    private var fileList: FileListWindowController?
    private var tidyWindow: DownloadTidyWindowController?
    /// Ebooks downloaded in the last month under site names, offered for tidying (0.20).
    private var tidyCandidates: [String] = []
    /// Files downloaded in the last week, for the menu (refreshed in the background).
    private var recentDownloads: [FileEntry] = []
    private var downloadsTimer: Timer?
    private var updater: Updater!
    private var updateWindow: UpdateProgressWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        service = IndexService(roots: Preferences.roots, rules: Preferences.rules)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        ocr = OCRService(directory: support.appendingPathComponent("KongSeek/OCR"))
        ocr.configure(Preferences.ocrSettings)
        searchWindow = SearchWindowController(service: service, ocr: ocr)
        searchWindow.onBatchRename = { [weak self] urls in self?.showBatchRename(adding: urls) }
        searchWindow.onFileList = { [weak self] source in self?.openFileList(source) }
        archives = ArchiveService(cacheURL: support.appendingPathComponent("KongSeek/archive-index.json"))
        updater = Updater(supportDirectory: support.appendingPathComponent("KongSeek", isDirectory: true))
        updater.onChange = { [weak self] in
            self?.settingsWindow?.refresh()
            self?.updateWindow?.refresh()
        }
        updater.onUpdateStarted = { [weak self] in self?.showUpdateProgress() }
        if Preferences.autoCheckUpdates { updater.startAutomaticChecks() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reportFinishedUpdate() }
        service.archives = archives.index

        clipboardHistory = ClipboardHistory(store: ClipboardStore(directory: support.appendingPathComponent("KongSeek/Clipboard", isDirectory: true)),
                                            limits: Preferences.clipboardLimits)
        clipboardMonitor = ClipboardMonitor(history: clipboardHistory)
        snippets = SnippetLibrary(fileURL: support.appendingPathComponent("KongSeek/snippets.json"))
        snippetExpansion = SnippetExpansionService(library: snippets, monitor: clipboardMonitor)
        snippetExpansion.enabled = Preferences.snippetExpansion
        clipboardPanel = ClipboardPanelController(monitor: clipboardMonitor, library: snippets)
        clipboardPanel.openSettings = { [weak self] in self?.openSettings() }
        clipboardHotKey = HotKey(id: 2) { [weak self] in self?.clipboardPanel.toggle() }
        clipboardHotKey.register(Preferences.clipboardShortcut)
        clipboardMonitor.start()
        lookupHotKey = HotKey(id: 3) { [weak self] in self?.lookUpSelection() }
        lookupHotKey.register(Preferences.lookupShortcut)
        service.onStateChange = { [weak self] state in
            guard let self else { return }
            self.searchWindow.indexStateChanged()
            // The archive list comes from the index, so scan once it is ready.
            if case .ready = state { self.refreshRecentDownloads() }
            if case .ready = state, !self.archivesStarted {
                self.archivesStarted = true
                self.configureArchives()
            }
        }
        hotKey = HotKey { [weak self] in self?.searchWindow.toggle() }
        hotKey.register(Preferences.searchShortcut)
        doubleTap.onDoubleTap = { [weak self] in self?.searchWindow.toggle() }
        doubleTap.trigger = Preferences.doubleTapModifier
        doubleTap.refresh()
        // Ask once for Input Monitoring (needed for the double tap); later the menu
        // and the settings window show how to grant it.
        if Preferences.doubleTapModifier != .off && !doubleTap.hasPermission && !UserDefaults.standard.bool(forKey: "askedInputMonitoring") {
            UserDefaults.standard.set(true, forKey: "askedInputMonitoring")
            _ = CGRequestListenEventAccess()
            doubleTap.refresh()
        }
        setUpStatusItem()
        service.start()
        if !Preferences.hasLaunchedBefore {
            Preferences.hasLaunchedBefore = true
            searchWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stop()
        clipboardHistory?.flush()
        service.saveNow()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "KongSeek")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt each time it opens, so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        var ways: [String] = []
        if let shortcut = hotKey.shortcut { ways.append(hotKey.isRegistered ? shortcut.display : "\(shortcut.display) 被占用") }
        let trigger = Preferences.doubleTapModifier
        if trigger != .off { ways.append("连按 \(trigger.title)") }
        if updater.state.hasUpdate && !updater.state.isBusy {
            let title = updater.state.remoteVersion.map { "⬆︎ 有新版本 \($0)，点此查看并安装…" } ?? "⬆︎ 有 \(updater.state.pending.count) 项更新，点此查看并安装…"
            menu.addItem(item(title, #selector(openUpdates)))
            menu.addItem(.separator())
        } else if case .updating(let step) = updater.state.phase {
            menu.addItem(item("更新中：\(step)（点此查看进度）", #selector(showUpdateProgress)))
            menu.addItem(.separator())
        }
        menu.addItem(item("打开搜索" + (ways.isEmpty ? "" : "（\(ways.joined(separator: " 或 "))）"), #selector(openSearch)))
        if trigger != .off && !doubleTap.isListening {
            menu.addItem(item("⚠︎ 连按 \(trigger.title) 尚未生效：需要“输入监控”权限…", #selector(openSettings)))
        }
        if let shortcut = hotKey.shortcut, !hotKey.isRegistered {
            menu.addItem(item("⚠︎ \(shortcut.display) 已被占用，点此更换…", #selector(openSettings)))
        }
        var clipboardTitle = "剪贴板历史"
        if let shortcut = clipboardHotKey.shortcut { clipboardTitle += "（\(clipboardHotKey.isRegistered ? shortcut.display : shortcut.display + " 被占用")）" }
        menu.addItem(item(clipboardTitle, #selector(openClipboard)))
        if !recentDownloads.isEmpty {
            let downloads = NSMenu()
            for entry in recentDownloads {
                let url = URL(fileURLWithPath: entry.path)
                let icon = NSWorkspace.shared.icon(forFile: entry.path)
                icon.size = NSSize(width: 16, height: 16)
                let open = ClosureMenuItem(title: entry.name, key: "") { NSWorkspace.shared.open(url) }
                open.image = icon
                open.toolTip = (entry.path as NSString).abbreviatingWithTildeInPath
                downloads.addItem(open)
                let reveal = ClosureMenuItem(title: "在访达中显示 " + entry.name, key: "") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                reveal.image = icon
                reveal.isAlternate = true
                reveal.keyEquivalentModifierMask = .option
                downloads.addItem(reveal)
            }
            downloads.addItem(.separator())
            downloads.addItem(ClosureMenuItem(title: "在搜索窗口中查看（dc:7d）", key: "") { [weak self] in self?.searchWindow.show(query: "dc:7d file: ") })
            let downloadsItem = NSMenuItem(title: "最近下载（7 天内）", action: nil, keyEquivalent: "")
            downloadsItem.submenu = downloads
            menu.addItem(downloadsItem)
        }
        if !tidyCandidates.isEmpty {
            menu.addItem(item("整理新下载的电子书（\(tidyCandidates.count) 本）…", #selector(openTidy)))
        }
        if Preferences.clipboardEnabled {
            menu.addItem(item(Preferences.clipboardPaused ? "继续记录剪贴板" : "暂停记录剪贴板", #selector(toggleClipboardPause)))
        }
        menu.addItem(.separator())

        menu.addItem(disabled(stateDescription))
        menu.addItem(item("立即重建索引", #selector(rebuildIndex)))
        menu.addItem(.separator())
        menu.addItem(item("文件清单（书单与参考文献）…", #selector(chooseFileListFolder)))
        menu.addItem(item("两版讲义对比…", #selector(openCompare)))
        menu.addItem(item("批量重命名…", #selector(openBatchRename)))
        menu.addItem(item("查找重复与相似文件…", #selector(openDuplicates)))
        menu.addItem(item("空间分析…", #selector(openSpace)))
        menu.addItem(item("查找扫描版 PDF…", #selector(openScannedPDFs)))
        menu.addItem(item("状态与诊断…", #selector(openStatus)))
        menu.addItem(.separator())
        menu.addItem(item("设置…", #selector(openSettings), key: ","))
        menu.addItem(item("关于 KongSeek", #selector(showAbout)))
        menu.addItem(item("退出 KongSeek", #selector(quit), key: "q"))
        // For the next time the menu opens.
        if case .ready = service.state { refreshRecentDownloads() }
    }

    private var stateDescription: String {
        switch service.state {
        case .loading:
            return "正在载入索引…"
        case .building(let entries):
            let estimate = service.buildEstimate
            return estimate > 0
                ? "正在重建索引 \(min(99, entries * 100 / estimate))% · 期间照常搜索"
                : "正在建立索引 · 已收录 \(entries.formatted()) 项"
        case .ready(let entries, let updated):
            let time = updated.formatted(date: .omitted, time: .shortened)
            return "已索引 \(entries.formatted()) 项 · 更新于 \(time)"
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func openSearch() {
        searchWindow.show()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                hotKey: hotKey,
                doubleTap: doubleTap,
                ocr: ocr,
                clipboardHotKey: clipboardHotKey,
                clipboardMonitor: clipboardMonitor,
                onClipboardSettingsChange: {},
                lookupHotKey: lookupHotKey,
                snippets: snippets,
                snippetExpansion: snippetExpansion,
                onIndexSettingsChange: { [weak self] in self?.applySettings() },
                onRebuild: { [weak self] in self?.service.rebuild() },
                indexStatus: { [weak self] in self?.stateDescription ?? "" },
                archives: archives,
                onArchiveSettingsChange: { [weak self] in self?.configureArchives() },
                updater: updater,
                diagnosticReport: { [weak self] in self?.diagnosticReport() ?? "" }
            )
        }
        settingsWindow?.show()
    }

    @objc private func showUpdateProgress() {
        if updateWindow == nil { updateWindow = UpdateProgressWindow(updater: updater) }
        updateWindow?.show()
    }

    /// After an update (or rollback) KongSeek is reopened by the installer; say
    /// whether the new version is the one now running.
    private func reportFinishedUpdate() {
        guard let previous = UserDefaults.standard.string(forKey: "updatedFrom") else { return }
        UserDefaults.standard.removeObject(forKey: "updatedFrom")
        let alert = NSAlert()
        if previous == Updater.version {
            alert.messageText = "更新没有完成"
            alert.informativeText = "KongSeek 仍是 \(previous)。安装时出了问题，已恢复原来的版本。详情见 设置 › 通用 › 更新日志。"
            alert.alertStyle = .warning
        } else {
            alert.messageText = "KongSeek 已更新到 \(Updater.version)"
            var notes = ""
            if let root = updater.state.sourceRoot,
               let changelog = try? String(contentsOfFile: root + "/CHANGELOG.md", encoding: .utf8) {
                notes = ReleaseNotes.sections(in: changelog, newerThan: previous)
                    .filter { !ReleaseNotes.isNewer($0.version, than: Updater.version) }
                    .map { "\($0.version)\n\($0.body)" }.joined(separator: "\n\n")
            }
            alert.informativeText = "原来的版本：\(previous)" + (notes.isEmpty ? "" : "\n\n" + notes)
        }
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openUpdates() {
        openSettings()
        settingsWindow?.show(general: true)
    }

    // MARK: - Diagnostics

    /// Plain-text status for the diagnostics zip (no clipboard contents, snippet text or file lists).
    private func diagnosticReport() -> String {
        func yes(_ value: Bool) -> String { value ? "是" : "否" }
        func time(_ date: Date?) -> String { date.map { ISO8601DateFormatter().string(from: $0) } ?? "-" }
        func shortcut(_ key: HotKey) -> String {
            guard let value = key.shortcut else { return "未设" }
            return value.display + (key.isRegistered ? "（已注册）" : "（被占用）")
        }
        var model = [CChar](repeating: 0, count: 256)
        var size = model.count
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let progress = ocr.progress
        let update = updater.state
        let lines: [String] = [
            "KongSeek \(Updater.version)（构建 \(Updater.build)，提交 \(Updater.installedCommit ?? "未记录")）",
            "生成时间：\(time(Date()))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(String(cString: model)) · \(ProcessInfo.processInfo.activeProcessorCount) 核",
            "位置：\(Bundle.main.bundlePath)",
            "签名：\(Updater.signingDescription())",
            "",
            "[权限]",
            "输入监控：\(yes(doubleTap.hasPermission))  辅助功能：\(yes(AXIsProcessTrusted()))",
            "",
            "[唤起]",
            "搜索 \(shortcut(hotKey))，剪贴板 \(shortcut(clipboardHotKey))，查词 \(shortcut(lookupHotKey))",
            "连按 \(Preferences.doubleTapModifier.title)：监听 \(yes(doubleTap.isListening))，最近按键 \(time(doubleTap.lastEventAt))，最近连按 \(time(doubleTap.lastFiredAt))",
            "",
            "[索引]",
            stateDescription,
            "文件夹：" + Preferences.roots.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "、"),
            "隐藏文件 \(yes(Preferences.includeHidden))，匹配所在文件夹 \(yes(Preferences.matchFolderPath))",
            "压缩包：\(Preferences.archiveSearch ? archives.statusText : "已关闭")",
            "",
            "[文字识别]",
            "启用 \(yes(Preferences.ocrEnabled))，\(Preferences.ocrFolders.count) 个文件夹，已识别 \(ocr.store.recognizedDocumentCount)，待识别 \(progress.pending)，暂停 \(yes(ocr.paused))，上次检查 \(time(progress.lastCheck))，上次错误：\(progress.lastError ?? "-")",
            "",
            "[剪贴板与片段]",
            "剪贴板：启用 \(yes(Preferences.clipboardEnabled))，暂停 \(yes(Preferences.clipboardPaused))，\(clipboardHistory.items.count) 条，\(clipboardHistory.totalBytes) 字节，问题：\(clipboardHistory.problem ?? "-")",
            "片段：\(snippets.snippets.count) 个，自动展开 \(yes(Preferences.snippetExpansion))，监听 \(yes(snippetExpansion.isListening))，上次展开 \(time(snippetExpansion.lastExpansion))，问题：\(snippetExpansion.lastProblem ?? "-")",
            "",
            "[更新]",
            "源码：\(update.sourceRoot ?? "-")，自动检查 \(yes(Preferences.autoCheckUpdates))，上次检查 \(time(update.lastCheck))，GitHub 新版本 \(update.remoteVersion ?? "-")，新提交 \(update.pending.count) 个",
            "状态：\(update.phase)",
            "备份：" + (update.backups.isEmpty ? "-" : update.backups.joined(separator: "、")),
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// The checks shown in 状态与诊断 (0.18): what works, and what needs the user.
    private func healthReport() -> [HealthItem] {
        var items: [HealthItem] = []
        let settings: (title: String, run: () -> Void) = ("打开设置", { [weak self] in self?.openSettings() })
        func time(_ date: Date?) -> String { date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "从未" }

        switch service.state {
        case .ready(let entries, let updated):
            items.append(HealthItem("索引", "已索引 \(entries.formatted()) 项", "更新于 \(time(updated))；文件夹：" + Preferences.roots.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "、"), .ok))
        case .building(let entries):
            items.append(HealthItem("索引", "正在建立索引", "已收录 \(entries.formatted()) 项；建好前搜索结果可能不全", .info))
        case .loading:
            items.append(HealthItem("索引", "正在载入索引", "通常几秒钟", .info))
        }

        if let shortcut = hotKey.shortcut {
            items.append(hotKey.isRegistered
                ? HealthItem("唤起", "快捷键 \(shortcut.display)", "可用", .ok)
                : HealthItem("唤起", "快捷键 \(shortcut.display) 被其他应用占用", "请换一个快捷键", .warning, action: settings))
        }
        let trigger = Preferences.doubleTapModifier
        if trigger != .off {
            items.append(doubleTap.hasPermission && doubleTap.isListening
                ? HealthItem("唤起", "连按 \(trigger.title)", "可用", .ok)
                : HealthItem("唤起", "连按 \(trigger.title) 未生效", "需要“输入监控”权限：设置 › 唤起 › 授予权限", .warning, action: settings))
        }
        if Preferences.autoPaste || Preferences.snippetExpansion {
            items.append(AXIsProcessTrusted()
                ? HealthItem("权限", "辅助功能", "已授权（直接粘贴、片段展开需要）", .ok)
                : HealthItem("权限", "辅助功能未授权", "直接粘贴和片段展开需要：系统设置 › 隐私与安全性 › 辅助功能 中打开 KongSeek", .warning,
                             action: ("打开系统设置", { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) })))
        }

        let progress = ocr.progress
        if Preferences.ocrEnabled && !Preferences.ocrFolders.isEmpty {
            var detail = "\(Preferences.ocrFolders.count) 个文件夹，已识别 \(ocr.store.recognizedDocumentCount) 个文件，待识别 \(progress.pending) 个"
            if let reason = progress.pausedReason { detail += "；\(reason)" }
            items.append(HealthItem("文字识别", "后台识别扫描件", detail, .ok))
            if let error = progress.lastError {
                items.append(HealthItem("文字识别", "上次识别出错", error, .warning))
            }
            if progress.lastInCloud > 0 && !Preferences.ocrDownloadFromICloud {
                items.append(HealthItem("文字识别", "\(progress.lastInCloud) 个文件只在 iCloud 中，未识别", "可在 设置 › 文字识别 中勾选“从 iCloud 下载”", .info, action: settings))
            }
        } else {
            items.append(HealthItem("文字识别", "未设置识别文件夹", "扫描版 PDF 的正文搜不到；可用“查找扫描版 PDF…”一键加入", .info,
                                    action: ("查找扫描版 PDF…", { [weak self] in self?.openScannedPDFs() })))
        }

        let update = updater.state
        switch update.phase {
        case .failed(let message):
            items.append(HealthItem("更新", "上次更新失败", message, .warning, action: ("查看", { [weak self] in self?.openUpdates() })))
        case .updating(let step):
            items.append(HealthItem("更新", "正在更新", step, .info))
        default:
            if update.hasUpdate {
                items.append(HealthItem("更新", "有新版本" + (update.remoteVersion.map { " \($0)" } ?? ""), "上次检查 \(time(update.lastCheck))", .info,
                                        action: ("查看并安装", { [weak self] in self?.openUpdates() })))
            } else {
                items.append(HealthItem("更新", "已是最新版本 \(Updater.version)", "上次检查 \(time(update.lastCheck))", .ok))
            }
        }

        let cli = CommandLineTool.status
        items.append(HealthItem("Claude 与命令行", "命令行工具 ks", cli, cli.hasPrefix("已安装") ? .ok : .info))
        let claude = ClaudeDesktop.status
        items.append(HealthItem("Claude 与命令行", "Claude 桌面版", claude + (Preferences.mcpReadContent ? "；允许读取正文" : "；只按文件名搜索"),
                                claude.hasPrefix("已添加（") ? .ok : .info))

        if Preferences.clipboardEnabled {
            if let problem = clipboardHistory.problem {
                items.append(HealthItem("剪贴板与片段", "剪贴板历史有问题", problem, .warning))
            } else {
                items.append(HealthItem("剪贴板与片段", "剪贴板历史", Preferences.clipboardPaused ? "已暂停记录" : "\(clipboardHistory.items.count) 条", .ok))
            }
        }
        if Preferences.snippetExpansion {
            items.append(snippetExpansion.isListening
                ? HealthItem("剪贴板与片段", "片段自动展开", "\(snippets.snippets.count) 个片段", .ok)
                : HealthItem("剪贴板与片段", "片段自动展开未生效", snippetExpansion.lastProblem ?? "需要“输入监控”和“辅助功能”权限", .warning, action: settings))
        }
        if Preferences.archiveSearch {
            items.append(HealthItem("其他", "压缩包内搜索", archives.statusText, .ok))
        }
        return items
    }

    /// ⌃⌥D: look up the text selected in the front app.
    private func lookUpSelection() {
        SelectedText.fetch(monitor: clipboardMonitor) { [weak self] text in
            self?.searchWindow.showLookup(text: text)
        }
    }

    @objc private func openClipboard() {
        clipboardPanel.show()
    }

    @objc private func toggleClipboardPause() {
        Preferences.clipboardPaused.toggle()
        if !Preferences.clipboardPaused { clipboardMonitor.skipCurrentContents() }
    }

    @objc private func rebuildIndex() {
        archivesStarted = false
        service.rebuild()
        searchWindow.show()
    }

    private func applySettings() {
        // The archives in the new index are scanned when it is ready.
        archivesStarted = false
        service.update(roots: Preferences.roots, rules: Preferences.rules)
    }

    /// Scans the .zip files in the index now and every two hours, or forgets them when turned off.
    private func configureArchives() {
        guard Preferences.archiveSearch else {
            archives.configure(source: nil)
            return
        }
        archives.configure(source: { [weak self] done in
            guard let self else { return done([]) }
            self.service.archivePaths(completion: done)
        })
    }

    private func openFileList(_ source: FileListSource) {
        if fileList == nil { fileList = FileListWindowController(service: service) }
        fileList?.present(source)
    }

    @objc private func openTidy() {
        if tidyWindow == nil { tidyWindow = DownloadTidyWindowController() }
        tidyWindow?.present(tidyCandidates)
    }

    @objc private func openCompare() {
        CompareWindowController.shared.present(old: nil, new: nil)
    }

    @objc private func chooseFileListFolder() {
        if fileList == nil { fileList = FileListWindowController(service: service) }
        fileList?.chooseFolder()
    }

    @objc func openStatus() {
        if statusWindow == nil {
            statusWindow = StatusWindowController(service: service, report: { [weak self] in self?.healthReport() ?? [] },
                                                  diagnosticText: { [weak self] in self?.diagnosticReport() ?? "" })
        }
        statusWindow?.present()
    }

    /// Finds files downloaded in the last week, for the menu; every five minutes and when the index is ready.
    private func refreshRecentDownloads() {
        if downloadsTimer == nil {
            let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.refreshRecentDownloads() }
            RunLoop.main.add(timer, forMode: .common)
            downloadsTimer = timer
        }
        service.recentDownloads { [weak self] entries in self?.recentDownloads = entries }
        service.recentDownloads(days: 30, limit: 300) { [weak self] entries in
            self?.tidyCandidates = DownloadTidyModel.candidates(entries)
        }
    }

    @objc private func openSpace() {
        if space == nil { space = SpaceWindowController(service: service) }
        space?.present()
    }

    @objc func openScannedPDFs() {
        if scanned == nil { scanned = ScannedPDFWindowController(service: service, ocr: ocr) }
        scanned?.present()
    }

    @objc private func openDuplicates() {
        if duplicates == nil { duplicates = DuplicatesWindowController(service: service) }
        duplicates?.present()
    }

    @objc private func openBatchRename() {
        showBatchRename(adding: [])
    }

    private func showBatchRename(adding urls: [URL]) {
        if batchRename == nil { batchRename = BatchRenameWindowController() }
        batchRename?.present(adding: urls)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
