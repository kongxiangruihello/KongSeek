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
    private var quoteHotKey: HotKey!
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
    private var quoteFinder: QuoteFinderWindowController?
    private var libraryCheck: LibraryCheckWindowController?
    private var bookTextWindow: BookTextWindowController?
    private var notesWindow: NotesWindowController?
    private var manuscriptCheck: ManuscriptCheckWindowController?
    private var featureGuide: FeatureGuideWindowController?
    private var trashLog: TrashLogWindowController?
    private var concordance: ConcordanceWindowController?
    private var whatsNew: WhatsNewWindowController?
    /// Checks every few seconds whether background work is running, for the menu bar icon (0.24).
    private var busyTimer: Timer?
    private var shownBusy = false
    /// Ebooks downloaded in the last month under site names, offered for tidying (0.20).
    private var tidyCandidates: [String] = []
    /// Files downloaded in the last week, for the menu (refreshed in the background).
    private var recentDownloads: [FileEntry] = []
    private var downloadsTimer: Timer?
    private var updater: Updater!
    private var updateWindow: UpdateProgressWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        StandardKeys.install()
        HangMonitor.shared.start()
        service = IndexService(roots: Preferences.roots, rules: Preferences.rules)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        ocr = OCRService(directory: support.appendingPathComponent("KongSeek/OCR"))
        ocr.configure(Preferences.ocrSettings)
        ReaderWindowController.ocrStore = ocr.store
        NotificationCenter.default.addObserver(forName: .ocrSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.ocr.configure(Preferences.ocrSettings)
        }
        NotificationCenter.default.addObserver(forName: BookTextService.openManager, object: nil, queue: .main) { [weak self] _ in
            self?.openBookText()
        }
        NotificationCenter.default.addObserver(forName: BookTextService.settingChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, Preferences.bookTextIndex else { return }
            BookTextService.shared.refresh(service: self.service)
        }
        searchWindow = SearchWindowController(service: service, ocr: ocr)
        searchWindow.onBatchRename = { [weak self] urls in self?.showBatchRename(adding: urls) }
        searchWindow.onFileList = { [weak self] source in self?.openFileList(source) }
        searchWindow.onConcordance = { [weak self] text in self?.openConcordance(query: text) }
        archives = ArchiveService(cacheURL: support.appendingPathComponent("KongSeek/archive-index.json"))
        updater = Updater(supportDirectory: support.appendingPathComponent("KongSeek", isDirectory: true))
        updater.onChange = { [weak self] in
            self?.settingsWindow?.refresh()
            self?.updateWindow?.refresh()
        }
        updater.onUpdateStarted = { [weak self] in self?.showUpdateProgress() }
        KongFolioInstaller.shared.updater = updater
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) { QuoteLookup.diskCache.trim() }
        KongFolioInstaller.shared.onChange = { [weak self] in self?.settingsWindow?.refresh() }
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
        quoteHotKey = HotKey(id: 4) { [weak self] in self?.checkSelectedQuote() }
        quoteHotKey.register(Preferences.quoteShortcut)
        service.onFilesChanged = { [weak self] paths in
            guard let self else { return }
            BookTextService.shared.noteChanges(paths, service: self.service)
        }
        service.onStateChange = { [weak self] state in
            guard let self else { return }
            self.searchWindow.indexStateChanged()
            // The archive list comes from the index, so scan once it is ready.
            if case .ready = state { self.refreshRecentDownloads() }
            if case .ready = state, !self.archivesStarted {
                self.archivesStarted = true
                self.configureArchives()
                // E-books Spotlight does not read (0.37), a little after the start.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self else { return }
                    BookTextService.shared.start(service: self.service)
                }
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
        // 记录备份 (0.44): once a day, checked at launch and every few hours.
        SettingsTransfer.backUpRecordsIfDue()
        let backupTimer = Timer(timeInterval: 4 * 3600, repeats: true) { _ in SettingsTransfer.backUpRecordsIfDue() }
        RunLoop.main.add(backupTimer, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.checkForCrashes() }
        if !Preferences.hasLaunchedBefore {
            Preferences.hasLaunchedBefore = true
            searchWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stop()
        clipboardHistory?.flush()
        Records.flush()
        service.saveNow()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "KongSeek")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.updateBusyIcon() }
        RunLoop.main.add(timer, forMode: .common)
        busyTimer = timer
    }

    // MARK: - Background work (0.24)

    /// Something KongSeek is doing in the background, for the menu.
    private struct RunningTask {
        var title: String
        var detail: String
        var stopTitle = "停止"
        var stop: (() -> Void)?
        var show: () -> Void
    }

    private func runningTasks() -> [RunningTask] {
        var tasks: [RunningTask] = []
        if case .building = service.state {
            tasks.append(RunningTask(title: "建立索引", detail: stateDescription, show: { [weak self] in self?.openStatus() }))
        }
        let recognition = ocr.progress
        if let file = recognition.currentFile {
            var detail = (file as NSString).lastPathComponent
            if recognition.currentPages > 1 { detail += " 第 \(recognition.currentPage) / \(recognition.currentPages) 页" }
            if recognition.pending > 1 { detail += " · 还有 \(recognition.pending - 1) 个文件" }
            tasks.append(RunningTask(title: "文字识别", detail: detail, stopTitle: "暂停文字识别",
                                     stop: { [weak self] in self?.ocr.setPaused(true) }, show: { [weak self] in self?.openSettings() }))
        }
        let books = BookTextService.shared
        if books.running, books.progress.total > 0 {
            let name = books.current.map { ($0 as NSString).lastPathComponent + " · " } ?? ""
            tasks.append(RunningTask(title: "建立正文索引（EPUB 等）", detail: name + "\(books.progress.done) / \(books.progress.total) 本",
                                     stopTitle: "停止", stop: { books.stop() }, show: { [weak self] in self?.openStatus() }))
        }
        if case .working(let step) = KongFolioInstaller.shared.phase {
            tasks.append(RunningTask(title: "安装 KongFolio", detail: step, show: { [weak self] in self?.openSettings() }))
        }
        let searchable = SearchablePDFWindowController.shared
        if searchable.model.running {
            let model = searchable.model
            let detail = (model.fileCount > 1 ? "第 \(model.fileIndex) / \(model.fileCount) 本 · " : "") + (model.pages > 0 ? "第 \(model.page) / \(model.pages) 页" : "正在打开")
            tasks.append(RunningTask(title: "生成可搜索的 PDF", detail: detail, stop: { model.stop() }, show: { searchable.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }))
        }
        let packager = CoursePackageWindowController.shared
        if packager.model.running {
            let model = packager.model
            tasks.append(RunningTask(title: "课程材料打包", detail: "\(model.done) / \(model.total) 个文件", stop: { model.stop() },
                                     show: { packager.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }))
        }
        if let window = manuscriptCheck, window.model.running {
            let rows = window.model.rows
            let done = rows.filter { $0.state == .done }.count
            tasks.append(RunningTask(title: "稿件引文核对", detail: "\(done) / \(rows.count) 条", stop: { window.model.stop() }, show: { window.present() }))
        }
        if let window = quoteFinder, window.model.running {
            let checked = window.model.checked
            tasks.append(RunningTask(title: "引文查证", detail: checked.total > 0 ? "已核对 \(checked.done) / \(checked.total) 个文件" : "正在查找",
                                     stop: { window.model.stop() }, show: { window.present() }))
        }
        if let window = concordance, window.model.running {
            let checked = window.model.checked
            tasks.append(RunningTask(title: "出处汇编", detail: "\(checked.done) / \(checked.total) 个文件，\(window.model.hitCount) 处", stop: { window.model.stop() },
                                     show: { window.present() }))
        }
        if let window = libraryCheck, window.model.running {
            let progress = window.model.progress
            tasks.append(RunningTask(title: "书库体检", detail: "\(progress.done) / \(progress.total) 个文件", stop: { window.model.stop() }, show: { window.present() }))
        }
        if let window = duplicates, window.model.running {
            tasks.append(RunningTask(title: "查找重复", detail: window.model.status, stop: { window.model.cancel() }, show: { window.present() }))
        }
        if let window = scanned, window.model.running {
            tasks.append(RunningTask(title: "查找扫描版 PDF", detail: "已检查 \(window.model.checked) 个", stop: { window.model.stop() }, show: { window.present() }))
        }
        if let window = space, window.model.running {
            tasks.append(RunningTask(title: "空间分析", detail: window.model.status, show: { window.present() }))
        }
        if let window = fileList, window.model.loading {
            let progress = window.model.progress
            tasks.append(RunningTask(title: "文件清单", detail: "正在读取 \(progress.done) / \(progress.total)", show: { window.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }))
        }
        return tasks
    }

    /// The menu bar icon shows a ring while anything runs in the background; its tooltip says what.
    private func updateBusyIcon() {
        let tasks = runningTasks()
        statusItem.button?.toolTip = TaskSummary.tooltip(tasks.map { (title: $0.title, detail: $0.detail) })
        let busy = !tasks.isEmpty
        guard busy != shownBusy else { return }
        shownBusy = busy
        statusItem.button?.image = NSImage(systemSymbolName: busy ? "magnifyingglass.circle" : "magnifyingglass", accessibilityDescription: "KongSeek")
    }

    private func addRunningTasks(to menu: NSMenu) {
        let tasks = runningTasks()
        guard !tasks.isEmpty else { return }
        menu.addItem(disabled("后台任务（\(tasks.count)）"))
        for task in tasks {
            let entry = NSMenuItem(title: "\(task.title)：\(task.detail)", action: nil, keyEquivalent: "")
            entry.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
            let actions = NSMenu()
            actions.addItem(ClosureMenuItem(title: "查看", key: "", handler: task.show))
            if let stop = task.stop { actions.addItem(ClosureMenuItem(title: task.stopTitle, key: "", handler: stop)) }
            entry.submenu = actions
            menu.addItem(entry)
        }
        menu.addItem(.separator())
    }

    // MARK: - Recent reading and saved lists (0.24)

    private func recentReadingItem() -> NSMenuItem? {
        let recent = PDFOpener.readingLog.recent(12) { FileManager.default.fileExists(atPath: $0) }
        guard !recent.isEmpty else { return nil }
        let menu = NSMenu()
        for entry in recent {
            let url = URL(fileURLWithPath: entry.path)
            let stem = url.deletingPathExtension().lastPathComponent
            let title = EbookName.parse(stem)?.title ?? stem
            let item = ClosureMenuItem(title: "\(title) — \(entry.progressText)", key: "") {
                PDFOpener.resume(url, at: entry.page)
            }
            let icon = NSWorkspace.shared.icon(forFile: entry.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.toolTip = (entry.path as NSString).abbreviatingWithTildeInPath + "\n" + entry.date.formatted(date: .abbreviated, time: .shortened) + " 读过"
            menu.addItem(item)
        }
        let parent = NSMenuItem(title: "最近阅读", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "book", accessibilityDescription: nil)
        parent.submenu = menu
        return parent
    }

    private func savedListsItem() -> NSMenuItem? {
        let lists = Records.lists.lists
        guard !lists.isEmpty else { return nil }
        let menu = NSMenu()
        for list in lists {
            let id = list.id
            menu.addItem(ClosureMenuItem(title: "\(list.name)（\(list.paths.count) 个文件）", key: "") { [weak self] in self?.openFileList(.saved(id)) })
        }
        let parent = NSMenuItem(title: "已保存的清单", action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    @objc func openConcordanceWindow() { openConcordance(query: nil) }

    func openConcordance(query: String?) {
        if concordance == nil { concordance = ConcordanceWindowController(ocr: ocr.store) }
        concordance?.present(query: query)
    }

    @objc func openTrashLog() {
        if trashLog == nil { trashLog = TrashLogWindowController() }
        trashLog?.present()
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
        addRunningTasks(to: menu)
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
        if let reading = recentReadingItem() { menu.addItem(reading) }
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
        // Grouped by what the work is for (0.23), instead of one long list.
        var quoteTitle = "引文查证…"
        if let shortcut = quoteHotKey.shortcut { quoteTitle += "（\(quoteHotKey.isRegistered ? shortcut.display : shortcut.display + " 被占用")）" }
        var writing = [
            item(quoteTitle, #selector(openQuoteFinder)),
            item("稿件引文核对…", #selector(openManuscriptCheck)),
            item("出处汇编…", #selector(openConcordanceWindow)),
            item("两版讲义对比…", #selector(openCompare)),
            item("文件清单（书单与参考文献）…", #selector(chooseFileListFolder)),
            item("备注一览…", #selector(openNotes)),
        ]
        if let lists = savedListsItem() { writing.append(lists) }
        menu.addItem(submenu("写作与引文", symbol: "text.quote", writing))
        menu.addItem(submenu("整理文件", symbol: "folder", [
            item("批量重命名…", #selector(openBatchRename)),
            item("查找重复与相似文件…", #selector(openDuplicates)),
            item("空间分析…", #selector(openSpace)),
            item("废纸篓记录（放回原处）…", #selector(openTrashLog)),
        ]))
        menu.addItem(submenu("书库", symbol: "books.vertical", [
            item("书库体检…", #selector(openLibraryCheck)),
            item("查找扫描版 PDF…", #selector(openScannedPDFs)),
            item("正文索引…", #selector(openBookText)),
        ]))
        menu.addItem(.separator())
        menu.addItem(item("功能导览…", #selector(openFeatureGuide)))
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

    private func submenu(_ title: String, symbol: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu()
        for entry in items { menu.addItem(entry) }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        parent.submenu = menu
        return parent
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
                quoteHotKey: quoteHotKey,
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
        guard previous != Updater.version else {
            let alert = NSAlert()
            alert.messageText = "更新没有完成"
            alert.informativeText = "KongSeek 仍是 \(previous)。安装时出了问题，已恢复原来的版本。详情见 设置 › 更新 › 更新日志。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        // What changed, in a window that scrolls (0.29) rather than a long alert.
        var sections: [ReleaseNotes.Section] = []
        if let root = updater.state.sourceRoot,
           let changelog = try? String(contentsOfFile: root + "/CHANGELOG.md", encoding: .utf8) {
            sections = ReleaseNotes.sections(in: changelog, newerThan: previous)
                .filter { !ReleaseNotes.isNewer($0.version, than: Updater.version) }
        }
        whatsNew = WhatsNewWindowController(version: Updater.version, previous: previous, sections: sections,
                                            openGuide: { [weak self] in self?.openFeatureGuide() },
                                            onClose: { [weak self] in DispatchQueue.main.async { self?.whatsNew = nil } })
        whatsNew?.present()
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
            "搜索 \(shortcut(hotKey))，剪贴板 \(shortcut(clipboardHotKey))，查词 \(shortcut(lookupHotKey))，引文查证 \(shortcut(quoteHotKey))",
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

        // 性能自检 (0.42): how long the last searches took.
        let timings = IndexService.timings
        let labels = ["载入索引", "名称搜索", "书目信息", "同义词扩展", "书目筛选", "全文搜索（Spotlight）", "正文索引搜索", "邻近核对", "命中统计",
                      "正文索引读取", "保存索引"]
        var anyTiming = false
        for label in labels {
            guard let summary = timings.summary(label) else { continue }
            anyTiming = true
            let slow: Double
            switch label {
            case "名称搜索", "书目信息": slow = 300
            case "全文搜索（Spotlight）", "正文索引搜索", "保存索引": slow = 5_000
            case "载入索引": slow = 10_000
            default: slow = 60_000
            }
            items.append(HealthItem("性能", label, summary, timings.slowest(label) > slow ? .warning : .ok))
        }
        if !anyTiming {
            items.append(HealthItem("性能", "还没有记录", "搜索几次后，这里列出各项用时（名称搜索、同义词、书目筛选、全文搜索等）", .info))
        }
        // 卡顿记录 (0.44).
        if let hitches = HangMonitor.shared.hitches.summary() {
            items.append(HealthItem("性能", "界面卡顿", hitches + "；界面停住半秒以上即记一次", .warning))
        } else {
            items.append(HealthItem("性能", "界面卡顿", "最近 7 天没有（界面停住半秒以上会记在这里）", .ok))
        }
        // 异常退出 (0.44): what macOS recorded in the last 7 days.
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let reports = CrashReport.newer(DiagnosticsBundle.appReports().map { $0.report }, than: weekAgo)
        if let latest = reports.first {
            let kinds = Dictionary(grouping: reports, by: { $0.kind }).map { "\($0.key) \($0.value.count) 次" }.sorted().joined(separator: "、")
            items.append(HealthItem("稳定性", "最近 7 天：" + kinds, "最近一次 \(time(latest.date))；导出诊断包会附上这些报告", .warning,
                                    action: ("导出诊断包…", { [weak self] in self?.exportDiagnostics() })))
        } else {
            items.append(HealthItem("稳定性", "最近 7 天没有异常退出", "系统没有记下 KongSeek 的崩溃、无响应或资源占用报告", .ok))
        }
        // 记录防损坏与备份 (0.44).
        let damaged = SettingsTransfer.damagedRecords
        if !damaged.isEmpty {
            items.append(HealthItem("稳定性", "\(damaged.count) 份记录读不出，已另存", damaged.map(\.lastPathComponent).joined(separator: "、")
                                    + "。原文件改名保留，未被覆盖；可从记录备份恢复，或把文件发给开发者", .warning,
                                    action: ("从备份恢复…", { SettingsTransfer.restoreBackup() })))
        }
        if let last = SettingsTransfer.lastRecordBackup {
            items.append(HealthItem("稳定性", "记录备份", "最近一次 \(last)；每天自动备份备注、补全的书目、书上页码、常用本等，保留 14 份", .ok,
                                    action: ("恢复…", { SettingsTransfer.restoreBackup() })))
        }

        // KongSeek's own text index (0.37).
        let books = BookTextService.shared
        if Preferences.bookTextIndex {
            let summary = books.index.summary
            var detail = "已收录 \(summary.books) 本（约 \(max(1, summary.characters / 10_000)) 万字），全文搜索、引文查证、出处汇编都会用到"
            if books.uncoveredFolderCount > 0 { detail += "；含 Spotlight 未收录的 \(books.uncoveredFolderCount) 个文件夹中的文稿" }
            if books.running { detail += "；正在读取 \(books.progress.done) / \(books.progress.total)" }
            items.append(HealthItem("正文索引", Preferences.indexUncoveredFolders ? "EPUB、Kindle、GB18030 文本，及 Spotlight 未收录的文稿" : "EPUB、Kindle 与 GB18030 文本", detail, .ok,
                                    action: ("管理…", { [weak self] in self?.openBookText() })))
            if summary.problems > 0 {
                items.append(HealthItem("正文索引", "\(summary.problems) 本读不出文字", "有 DRM 保护、用了不支持的压缩方式（如 HUFF/CDIC），或文件已损坏", .info))
            }
        } else {
            items.append(HealthItem("正文索引", "已关闭", "EPUB、Kindle 等电子书的正文搜不到；可在 设置 › 搜索 中打开", .info, action: settings))
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
        items += kongFolioHealth()
        let cacheSize = QuoteLookup.diskCache.size
        if cacheSize > 0 {
            items.append(HealthItem("其他", "引文查证的文字缓存", ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
                                    + "（读过的书的文字，文件改动后自动重读；上限 300 MB）", .ok,
                                    action: ("清除", { DispatchQueue.global(qos: .utility).async { QuoteLookup.diskCache.clear() } })))
        }
        return items
    }

    /// KongFolio 联动自检 (0.26): installed, new enough, its links registered, its reading progress readable.
    private func kongFolioHealth() -> [HealthItem] {
        let group = "KongFolio 联动"
        let install: (title: String, run: () -> Void) = ("安装或更新…", { [weak self] in self?.openUpdates() })
        guard let app = KongFolio.appURL else {
            if Preferences.pdfReader == .builtIn { return [] }
            return [HealthItem(group, "没有找到 KongFolio", "PDF 在 KongSeek 自己的阅读窗口中打开；装上 KongFolio 后自动改用它", .info, action: install)]
        }
        var items: [HealthItem] = []
        let version = KongFolio.installedVersion ?? "?"
        let place = (app.path as NSString).abbreviatingWithTildeInPath
        if KongFolioLink.isLinked(version: version) {
            items.append(HealthItem(group, "KongFolio \(version)", "位置：\(place)", .ok))
        } else {
            items.append(HealthItem(group, "KongFolio \(version) 较旧", "需要 \(KongFolioLink.linkedVersion) 起才能保留标记、接着上次读、显示阅读时间；位置：\(place)", .warning, action: install))
        }
        items.append(KongFolio.isReader
            ? HealthItem(group, "PDF 在 KongFolio 中打开", "⌥↩、引文查证的“打开到此处”、最近阅读", .ok)
            : HealthItem(group, "PDF 在 KongSeek 阅读窗口中打开", "设置 › 通用 › PDF 阅读 中可改为 KongFolio", .info, action: ("打开设置", { [weak self] in self?.openSettings() })))
        let handler = URL(string: "kongfolio://source").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        if let handler, handler.standardizedFileURL.path == app.standardizedFileURL.path {
            items.append(HealthItem(group, "按页打开的链接", "kongfolio:// 由 \(place) 打开", .ok))
        } else {
            items.append(HealthItem(group, "按页打开的链接没有交给这个 KongFolio",
                                    handler.map { "现在由 \(($0.path as NSString).abbreviatingWithTildeInPath) 打开；可能有多份 KongFolio，请删掉不用的那份" }
                                        ?? "系统没有登记 kongfolio:// 链接；打开一次 KongFolio 通常就会登记",
                                    .warning))
        }
        let progress = KongFolio.readingEntries()
        items.append(progress.isEmpty
            ? HealthItem(group, "还没有读到 KongFolio 的阅读进度", "在 KongFolio 中读书、每页停留一会儿后就会有", .info)
            : HealthItem(group, "阅读进度", "读到 \(progress.count) 本书的进度" + (progress.contains { $0.date > .distantPast } ? "" : "（尚无阅读时间，需 KongFolio 0.34 起）"), .ok))
        return items
    }

    /// ⌃⌥Q: checks the text selected in the front app with 引文查证 (0.23).
    private func checkSelectedQuote() {
        SelectedText.fetch(monitor: clipboardMonitor) { [weak self] text in
            guard let self else { return }
            self.makeQuoteFinder()
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                self.quoteFinder?.present()
                self.quoteFinder?.model.note("没有读到选中的文字：请先选中一句引文再按快捷键（读取选中文字需要“辅助功能”权限），或直接粘贴到这里。")
            } else {
                self.quoteFinder?.present(quote: trimmed)
            }
        }
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

    private func makeQuoteFinder() {
        guard quoteFinder == nil else { return }
        quoteFinder = QuoteFinderWindowController(ocr: ocr.store)
        quoteFinder?.model.openManuscriptCheck = { [weak self] in self?.openManuscriptCheck() }
        quoteFinder?.model.checkPassage = { [weak self] text in self?.checkPassage(text) }
    }

    @objc private func openQuoteFinder() {
        makeQuoteFinder()
        // A quotation just copied (4–300 characters of text) is filled in, not yet checked.
        if let model = quoteFinder?.model, model.quote.isEmpty, let copied = NSPasteboard.general.string(forType: .string),
           (4...300).contains(copied.trimmingCharacters(in: .whitespacesAndNewlines).count) {
            model.quote = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        quoteFinder?.present()
    }

    @objc func openManuscriptCheck() {
        if manuscriptCheck == nil { manuscriptCheck = ManuscriptCheckWindowController(ocr: ocr.store) }
        manuscriptCheck?.present()
    }

    /// The quotations of a passage pasted into 引文查证, checked one by one (0.32).
    private func checkPassage(_ text: String) {
        if manuscriptCheck == nil { manuscriptCheck = ManuscriptCheckWindowController(ocr: ocr.store) }
        manuscriptCheck?.present(text: text)
    }

    @objc func openFeatureGuide() {
        if featureGuide == nil {
            featureGuide = FeatureGuideWindowController { [weak self] action in self?.runFeature(action) }
        }
        featureGuide?.present()
    }

    /// Runs a feature from the guide.
    private func runFeature(_ action: FeatureGuide.Action) {
        switch action {
        case .search(let query): searchWindow.show(query: query)
        case .openSearch: searchWindow.show()
        case .clipboard: openClipboard()
        case .quoteFinder: openQuoteFinder()
        case .manuscriptCheck: openManuscriptCheck()
        case .compare: openCompare()
        case .fileList: chooseFileListFolder()
        case .batchRename: openBatchRename()
        case .duplicates: openDuplicates()
        case .space: openSpace()
        case .libraryCheck: openLibraryCheck()
        case .scannedPDFs: openScannedPDFs()
        case .status: openStatus()
        case .settings: openSettings()
        case .trashLog: openTrashLog()
        case .concordance: openConcordance(query: nil)
        case .bookText: openBookText()
        case .notes: openNotes()
        }
    }

    /// 异常退出提示 (0.44): when macOS wrote a new crash or hang report about KongSeek since
    /// the last check, says so once and offers the diagnostics package.
    private func checkForCrashes() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reports = DiagnosticsBundle.appReports().map { $0.report }
            DispatchQueue.main.async {
                guard let self else { return }
                let since = Preferences.lastCrashCheck
                if let newest = reports.first?.date { Preferences.lastCrashCheck = max(newest, since ?? .distantPast) }
                // The first check (just updated to 0.44) only notes where things stand.
                guard let since else {
                    if reports.isEmpty { Preferences.lastCrashCheck = Date() }
                    return
                }
                let fresh = CrashReport.newer(reports, than: since).filter { $0.kind == "异常退出" || $0.kind == "无响应" }
                guard let latest = fresh.first else { return }
                let alert = NSAlert()
                alert.messageText = latest.kind == "无响应" ? "KongSeek 上次曾长时间无响应" : "KongSeek 上次异常退出"
                alert.informativeText = "时间：\(latest.date.formatted(date: .abbreviated, time: .shortened))"
                    + (fresh.count > 1 ? "（此后共 \(fresh.count) 次）" : "") + "。\n\n"
                    + "可以导出诊断包（含系统记下的报告、更新与构建日志，不含片段和剪贴板内容）发给开发者，便于找出原因。以后也可在 状态与诊断 中查看。"
                alert.addButton(withTitle: "导出诊断包…")
                alert.addButton(withTitle: "以后再说")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { self.exportDiagnostics() }
            }
        }
    }

    private func exportDiagnostics() {
        DiagnosticsBundle.export(report: diagnosticReport(), updateLog: updater.logURL, sourceRoot: updater.state.sourceRoot)
    }

    /// 正文索引管理 (0.43).
    @objc func openBookText() {
        if bookTextWindow == nil { bookTextWindow = BookTextWindowController(service: service, ocr: ocr) }
        bookTextWindow?.present()
    }

    /// 备注一览 (0.43).
    @objc func openNotes() {
        if notesWindow == nil { notesWindow = NotesWindowController() }
        notesWindow?.present()
    }

    @objc private func openLibraryCheck() {
        if libraryCheck == nil {
            libraryCheck = LibraryCheckWindowController(service: service)
            libraryCheck?.model.openDuplicates = { [weak self] in self?.openDuplicates() }
        }
        libraryCheck?.present()
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
