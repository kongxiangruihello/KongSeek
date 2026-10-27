import AppKit
import ServiceManagement
import KongSeekCore

/// The settings window: how the search window opens, and what is indexed.
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let window: NSWindow
    private let hotKey: HotKey
    private let doubleTap: DoubleTapMonitor
    private let ocr: OCRService
    private let clipboardHotKey: HotKey
    private let clipboardMonitor: ClipboardMonitor
    private let onClipboardSettingsChange: () -> Void
    private let snippetPage: SnippetSettingsView
    private let quickLinkPage: QuickLinkSettingsView
    private let generalPage: GeneralSettingsView
    private let tabs = NSTabView()

    private let clipEnabledCheckbox = NSButton(checkboxWithTitle: "记录剪贴板历史（文字、图片、文件）", target: nil, action: nil)
    private let clipRecorder = ShortcutRecorderButton()
    private let clipShortcutNote = NSTextField(labelWithString: "")
    private let clipRetentionPopup = NSPopUpButton()
    private let clipCountPopup = NSPopUpButton()
    private let autoPasteCheckbox = NSButton(checkboxWithTitle: "选中后直接粘贴到原来的应用（需要“辅助功能”权限）", target: nil, action: nil)
    private let accessibilityButton = NSButton(title: "授予“辅助功能”权限…", target: nil, action: nil)
    private let clipOCRCheckbox = NSButton(checkboxWithTitle: "识别复制的图片中的文字（可搜索，⇧↩ 粘贴文字）", target: nil, action: nil)
    private let clipStatusLabel = NSTextField(wrappingLabelWithString: "")
    private static let retentionChoices = [(7, "7 天"), (30, "30 天"), (90, "90 天"), (365, "1 年"), (0, "永久")]
    private static let countChoices = [100, 300, 1000, 2000]
    private let onIndexSettingsChange: () -> Void
    private let onRebuild: () -> Void
    private let indexStatus: () -> String

    private let recorder = ShortcutRecorderButton()
    private let shortcutNote = NSTextField(wrappingLabelWithString: "")
    private let tapPopup = NSPopUpButton()
    private let tapNote = NSTextField(wrappingLabelWithString: "")
    private let permissionButton = NSButton(title: "授予“输入监控”权限…", target: nil, action: nil)
    private var refreshTimer: Timer?

    private let folderTable = NSTableView()
    private var folders: [String] = []
    private let hiddenCheckbox = NSButton(checkboxWithTitle: "包含隐藏文件和文件夹（名称以 . 开头）", target: nil, action: nil)
    private let pathCheckbox = NSButton(checkboxWithTitle: "关键词也匹配所在文件夹的路径", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "登录时自动启动 KongSeek", target: nil, action: nil)
    private let indexStatusLabel = NSTextField(labelWithString: "")
    private let archives: ArchiveService
    private let onArchiveSettingsChange: () -> Void
    private let archiveCheckbox = NSButton(checkboxWithTitle: "也搜索 zip 压缩包里的文件名（不必解压）", target: nil, action: nil)
    private let archiveStatusLabel = NSTextField(labelWithString: "")
    private let archiveScanButton = NSButton(title: "立即扫描", target: nil, action: nil)

    private let ocrTable = NSTableView()
    private var ocrFolders: [String] = []
    private let ocrEnabledCheckbox = NSButton(checkboxWithTitle: "识别所选文件夹中扫描版 PDF 和图片的文字，供全文搜索", target: nil, action: nil)
    private let ocrPowerCheckbox = NSButton(checkboxWithTitle: "只在接通电源时识别", target: nil, action: nil)
    private let ocrCloudCheckbox = NSButton(checkboxWithTitle: "先下载只存于 iCloud 的文件再识别（占用本机空间）", target: nil, action: nil)
    private let ocrPagePopup = NSPopUpButton()
    private let ocrStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let ocrPauseButton = NSButton(title: "暂停", target: nil, action: nil)
    private static let pageLimits = [50, 200, 500, 1000]

    init(hotKey: HotKey, doubleTap: DoubleTapMonitor, ocr: OCRService, clipboardHotKey: HotKey, clipboardMonitor: ClipboardMonitor,
         onClipboardSettingsChange: @escaping () -> Void, lookupHotKey: HotKey, snippets: SnippetLibrary,
         snippetExpansion: SnippetExpansionService, onIndexSettingsChange: @escaping () -> Void, onRebuild: @escaping () -> Void, indexStatus: @escaping () -> String,
         archives: ArchiveService, onArchiveSettingsChange: @escaping () -> Void,
         updater: Updater, diagnosticReport: @escaping () -> String) {
        generalPage = GeneralSettingsView(updater: updater, library: snippets, diagnosticReport: diagnosticReport)
        self.archives = archives
        self.onArchiveSettingsChange = onArchiveSettingsChange
        self.hotKey = hotKey
        self.doubleTap = doubleTap
        self.ocr = ocr
        self.clipboardHotKey = clipboardHotKey
        self.clipboardMonitor = clipboardMonitor
        self.onClipboardSettingsChange = onClipboardSettingsChange
        snippetPage = SnippetSettingsView(library: snippets, expansion: snippetExpansion)
        quickLinkPage = QuickLinkSettingsView(lookupHotKey: lookupHotKey)
        self.onIndexSettingsChange = onIndexSettingsChange
        self.onRebuild = onRebuild
        self.indexStatus = indexStatus
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 710), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        window.title = "KongSeek 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildLayout()
    }

    /// Shows the window, on the "通用" page when `general` is set (update notices).
    func show(general: Bool = false) {
        if general { tabs.selectTabViewItem(withIdentifier: "general") }
        refresh()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refreshTimer?.invalidate()
        // Picks up a permission granted in System Settings while this window is open.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        recorder.stopRecording()
        clipRecorder.stopRecording()
    }

    private func buildLayout() {
        let launchTab = NSTabViewItem(identifier: "launch")
        launchTab.label = "唤起"
        launchTab.view = buildLaunchView()
        let indexTab = NSTabViewItem(identifier: "index")
        indexTab.label = "索引"
        indexTab.view = buildIndexView()
        tabs.addTabViewItem(launchTab)
        tabs.addTabViewItem(indexTab)
        let ocrTab = NSTabViewItem(identifier: "ocr")
        ocrTab.label = "文字识别"
        ocrTab.view = buildOCRView()
        tabs.addTabViewItem(ocrTab)
        let clipTab = NSTabViewItem(identifier: "clipboard")
        clipTab.label = "剪贴板"
        clipTab.view = buildClipboardView()
        tabs.addTabViewItem(clipTab)
        let snippetTab = NSTabViewItem(identifier: "snippets")
        snippetTab.label = "片段"
        snippetTab.view = snippetPage
        tabs.addTabViewItem(snippetTab)
        let linkTab = NSTabViewItem(identifier: "links")
        linkTab.label = "网页搜索"
        linkTab.view = quickLinkPage
        tabs.addTabViewItem(linkTab)
        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "通用"
        generalTab.view = generalPage
        tabs.addTabViewItem(generalTab)
        let container = NSView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        window.contentView = container
    }

    private func buildLaunchView() -> NSView {
        let content = NSView()

        let shortcutLabel = NSTextField(labelWithString: "唤起快捷键：")
        recorder.onRecord = { [weak self] shortcut in self?.apply(shortcut) }
        recorder.onRecordingChange = { [weak self] recording in
            if recording { self?.hotKey.suspend() } else { self?.hotKey.resume() }
        }
        let resetButton = NSButton(title: "恢复 ⌥空格", target: self, action: #selector(resetShortcut))
        resetButton.bezelStyle = .rounded

        let tapLabel = NSTextField(labelWithString: "连按两次唤起：")
        for modifier in TapModifier.allCases {
            tapPopup.addItem(withTitle: modifier.title)
            tapPopup.lastItem?.representedObject = modifier.rawValue
        }
        tapPopup.target = self
        tapPopup.action = #selector(tapChanged)
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        permissionButton.bezelStyle = .rounded

        for note in [shortcutNote, tapNote] {
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = 300
        }

        for view in [shortcutLabel, recorder, resetButton, shortcutNote, tapLabel, tapPopup, tapNote, permissionButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            shortcutLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            shortcutLabel.widthAnchor.constraint(equalToConstant: 110),
            shortcutLabel.centerYAnchor.constraint(equalTo: recorder.centerYAnchor),
            recorder.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            recorder.leadingAnchor.constraint(equalTo: shortcutLabel.trailingAnchor, constant: 8),
            recorder.widthAnchor.constraint(equalToConstant: 170),
            resetButton.leadingAnchor.constraint(equalTo: recorder.trailingAnchor, constant: 8),
            resetButton.centerYAnchor.constraint(equalTo: recorder.centerYAnchor),
            shortcutNote.topAnchor.constraint(equalTo: recorder.bottomAnchor, constant: 6),
            shortcutNote.leadingAnchor.constraint(equalTo: recorder.leadingAnchor),
            shortcutNote.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),

            tapLabel.leadingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor),
            tapLabel.widthAnchor.constraint(equalToConstant: 110),
            tapLabel.centerYAnchor.constraint(equalTo: tapPopup.centerYAnchor),
            tapPopup.topAnchor.constraint(equalTo: shortcutNote.bottomAnchor, constant: 22),
            tapPopup.leadingAnchor.constraint(equalTo: recorder.leadingAnchor),
            tapPopup.widthAnchor.constraint(equalToConstant: 170),
            tapNote.topAnchor.constraint(equalTo: tapPopup.bottomAnchor, constant: 6),
            tapNote.leadingAnchor.constraint(equalTo: recorder.leadingAnchor),
            tapNote.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            permissionButton.topAnchor.constraint(equalTo: tapNote.bottomAnchor, constant: 8),
            permissionButton.leadingAnchor.constraint(equalTo: recorder.leadingAnchor),
            permissionButton.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
        return content
    }

    private func buildIndexView() -> NSView {
        let content = NSView()
        let title = NSTextField(labelWithString: "索引的文件夹：")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        folderTable.addTableColumn(column)
        folderTable.headerView = nil
        folderTable.dataSource = self
        folderTable.delegate = self
        folderTable.rowHeight = 22
        folderTable.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = folderTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: "添加…", target: self, action: #selector(addFolder))
        let remove = NSButton(title: "移除", target: self, action: #selector(removeFolder))
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetFolders))
        let note = NSTextField(wrappingLabelWithString: "默认：主目录、iCloud 云盘、应用程序。主目录下的 ~/Library、node_modules、.git、DerivedData 和废纸篓不收录。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 440

        for checkbox in [hiddenCheckbox, pathCheckbox, loginCheckbox, archiveCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(checkboxChanged(_:))
        }
        indexStatusLabel.font = .systemFont(ofSize: 11)
        indexStatusLabel.textColor = .secondaryLabelColor
        let rebuild = NSButton(title: "立即重建索引", target: self, action: #selector(rebuildIndex))
        archiveStatusLabel.font = .systemFont(ofSize: 11)
        archiveStatusLabel.textColor = .secondaryLabelColor
        archiveStatusLabel.lineBreakMode = .byTruncatingTail
        archiveScanButton.target = self
        archiveScanButton.action = #selector(scanArchives)
        archiveScanButton.controlSize = .small

        for view in [title, scroll, add, remove, reset, note, hiddenCheckbox, pathCheckbox, loginCheckbox, archiveCheckbox, archiveScanButton, archiveStatusLabel,
                     indexStatusLabel, rebuild] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.heightAnchor.constraint(equalToConstant: 110),
            add.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            add.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            remove.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            remove.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 6),
            reset.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            reset.leadingAnchor.constraint(equalTo: remove.trailingAnchor, constant: 6),
            note.topAnchor.constraint(equalTo: add.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            hiddenCheckbox.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 14),
            hiddenCheckbox.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            pathCheckbox.topAnchor.constraint(equalTo: hiddenCheckbox.bottomAnchor, constant: 8),
            pathCheckbox.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            loginCheckbox.topAnchor.constraint(equalTo: pathCheckbox.bottomAnchor, constant: 8),
            loginCheckbox.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            archiveCheckbox.topAnchor.constraint(equalTo: loginCheckbox.bottomAnchor, constant: 8),
            archiveCheckbox.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            archiveScanButton.topAnchor.constraint(equalTo: archiveCheckbox.bottomAnchor, constant: 4),
            archiveScanButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 18),
            archiveStatusLabel.centerYAnchor.constraint(equalTo: archiveScanButton.centerYAnchor),
            archiveStatusLabel.leadingAnchor.constraint(equalTo: archiveScanButton.trailingAnchor, constant: 8),
            archiveStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor),
            rebuild.topAnchor.constraint(equalTo: archiveScanButton.bottomAnchor, constant: 16),
            rebuild.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            indexStatusLabel.centerYAnchor.constraint(equalTo: rebuild.centerYAnchor),
            indexStatusLabel.leadingAnchor.constraint(equalTo: rebuild.trailingAnchor, constant: 10),
            indexStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor),
            rebuild.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
        ])
        return content
    }

    // MARK: - OCR tab

    private func buildOCRView() -> NSView {
        let content = NSView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ocrFolder"))
        ocrTable.addTableColumn(column)
        ocrTable.headerView = nil
        ocrTable.dataSource = self
        ocrTable.delegate = self
        ocrTable.rowHeight = 22
        ocrTable.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = ocrTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let add = NSButton(title: "添加文件夹…", target: self, action: #selector(addOCRFolder))
        let remove = NSButton(title: "移除", target: self, action: #selector(removeOCRFolder))
        let note = NSTextField(wrappingLabelWithString: "用本机 Apple Vision 识别简体、繁体中文和英文，不上传。带文字层的 PDF 交给 Spotlight，不重复识别。识别结果在全文模式（⇥）中可搜，标为“识别文字”。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 440
        let pageLabel = NSTextField(labelWithString: "每个 PDF 最多识别：")
        for limit in Self.pageLimits { ocrPagePopup.addItem(withTitle: "\(limit) 页") }
        ocrPagePopup.target = self
        ocrPagePopup.action = #selector(ocrPageLimitChanged)
        for checkbox in [ocrEnabledCheckbox, ocrPowerCheckbox, ocrCloudCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(ocrCheckboxChanged(_:))
        }
        ocrStatusLabel.font = .systemFont(ofSize: 11)
        ocrStatusLabel.textColor = .secondaryLabelColor
        ocrStatusLabel.preferredMaxLayoutWidth = 440
        ocrPauseButton.target = self
        ocrPauseButton.action = #selector(toggleOCRPause)
        let check = NSButton(title: "立即检查", target: self, action: #selector(checkOCRNow))
        let clear = NSButton(title: "清除识别结果", target: self, action: #selector(clearOCR))
        let findScanned = NSButton(title: "查找扫描版 PDF…", target: self, action: #selector(findScannedPDFs))
        findScanned.toolTip = "在已索引的文件夹中找出没有文字层的 PDF，按文件夹列出，一键加入上面的列表"

        let views: [NSView] = [ocrEnabledCheckbox, scroll, add, remove, findScanned, note, pageLabel, ocrPagePopup, ocrPowerCheckbox, ocrCloudCheckbox, ocrStatusLabel, ocrPauseButton, check, clear]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            ocrEnabledCheckbox.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            ocrEnabledCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: ocrEnabledCheckbox.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: ocrEnabledCheckbox.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.heightAnchor.constraint(equalToConstant: 80),
            add.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            add.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            remove.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            remove.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 6),
            findScanned.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            findScanned.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            note.topAnchor.constraint(equalTo: add.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            pageLabel.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 12),
            pageLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            ocrPagePopup.centerYAnchor.constraint(equalTo: pageLabel.centerYAnchor),
            ocrPagePopup.leadingAnchor.constraint(equalTo: pageLabel.trailingAnchor, constant: 6),
            ocrPowerCheckbox.topAnchor.constraint(equalTo: pageLabel.bottomAnchor, constant: 10),
            ocrPowerCheckbox.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            ocrCloudCheckbox.topAnchor.constraint(equalTo: ocrPowerCheckbox.bottomAnchor, constant: 6),
            ocrCloudCheckbox.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            ocrStatusLabel.topAnchor.constraint(equalTo: ocrCloudCheckbox.bottomAnchor, constant: 10),
            ocrStatusLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            ocrStatusLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            ocrPauseButton.topAnchor.constraint(equalTo: ocrStatusLabel.bottomAnchor, constant: 8),
            ocrPauseButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            check.centerYAnchor.constraint(equalTo: ocrPauseButton.centerYAnchor),
            check.leadingAnchor.constraint(equalTo: ocrPauseButton.trailingAnchor, constant: 6),
            clear.centerYAnchor.constraint(equalTo: ocrPauseButton.centerYAnchor),
            clear.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6),
            ocrPauseButton.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -14),
        ])
        return content
    }

    private func refreshOCR() {
        if ocrFolders != Preferences.ocrFolders {
            ocrFolders = Preferences.ocrFolders
            ocrTable.reloadData()
        }
        ocrEnabledCheckbox.state = Preferences.ocrEnabled ? .on : .off
        ocrPowerCheckbox.state = Preferences.ocrOnlyOnPower ? .on : .off
        ocrCloudCheckbox.state = Preferences.ocrDownloadFromICloud ? .on : .off
        ocrPagePopup.selectItem(at: Self.pageLimits.firstIndex(of: Preferences.ocrPageLimit) ?? 1)
        ocrPauseButton.title = ocr.paused ? "继续" : "暂停"
        ocrStatusLabel.stringValue = ocrStatusText
    }

    private var ocrStatusText: String {
        guard Preferences.ocrEnabled else { return "文字识别已关闭。" }
        guard !Preferences.ocrFolders.isEmpty else { return "还没有选择文件夹。添加放扫描件的文件夹后会在后台开始识别。" }
        let progress = ocr.progress
        var parts = ["已识别 \(ocr.store.recognizedDocumentCount) 个文件"]
        if let reason = progress.pausedReason {
            parts.append(reason)
        } else if let file = progress.currentFile {
            parts.append("正在识别：\(file)（第 \(progress.currentPage)/\(progress.currentPages) 页），还剩 \(progress.pending) 个")
        } else if let check = progress.lastCheck {
            parts.append("上次检查 \(check.formatted(date: .omitted, time: .shortened))")
        }
        if progress.lastInCloud > 0 {
            parts.append(Preferences.ocrDownloadFromICloud ? "\(progress.lastInCloud) 个正从 iCloud 下载" : "\(progress.lastInCloud) 个只在 iCloud 中，已跳过")
        }
        if let error = progress.lastError { parts.append("最近错误：\(error)") }
        return parts.joined(separator: "；")
    }

    private func ocrSettingsChanged() {
        ocr.configure(Preferences.ocrSettings)
        refresh()
    }

    @objc private func addOCRFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "识别"
        panel.message = "选择存放扫描版 PDF 或图片的文件夹"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            var list = Preferences.ocrFolders
            for url in panel.urls where !list.contains(url.path) { list.append(url.path) }
            Preferences.ocrFolders = list
            self.ocrSettingsChanged()
        }
    }

    @objc private func findScannedPDFs() {
        (NSApp.delegate as? AppDelegate)?.openScannedPDFs()
    }

    @objc private func removeOCRFolder() {
        let row = ocrTable.selectedRow
        guard row >= 0 && row < ocrFolders.count else { return }
        var list = Preferences.ocrFolders
        list.removeAll { $0 == ocrFolders[row] }
        Preferences.ocrFolders = list
        ocrSettingsChanged()
    }

    @objc private func ocrCheckboxChanged(_ sender: NSButton) {
        switch sender {
        case ocrEnabledCheckbox: Preferences.ocrEnabled = sender.state == .on
        case ocrPowerCheckbox: Preferences.ocrOnlyOnPower = sender.state == .on
        case ocrCloudCheckbox: Preferences.ocrDownloadFromICloud = sender.state == .on
        default: break
        }
        ocrSettingsChanged()
    }

    @objc private func ocrPageLimitChanged() {
        let index = ocrPagePopup.indexOfSelectedItem
        guard Self.pageLimits.indices.contains(index) else { return }
        Preferences.ocrPageLimit = Self.pageLimits[index]
        ocrSettingsChanged()
    }

    @objc private func toggleOCRPause() {
        ocr.setPaused(!ocr.paused)
        refresh()
    }

    @objc private func checkOCRNow() {
        ocr.checkNow()
        refresh()
    }

    @objc private func clearOCR() {
        let alert = NSAlert()
        alert.messageText = "清除全部识别结果？"
        alert.informativeText = "已识别的文字会删除，之后在后台重新识别。原文件不受影响。"
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.ocr.clearResults()
            self?.refresh()
        }
    }

    // MARK: - Index tab

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === ocrTable ? ocrFolders.count : folders.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let list = tableView === ocrTable ? ocrFolders : folders
        let label = NSTextField(labelWithString: (list[row] as NSString).abbreviatingWithTildeInPath)
        label.lineBreakMode = .byTruncatingMiddle
        let exists = FileManager.default.fileExists(atPath: list[row])
        label.textColor = exists ? .labelColor : .secondaryLabelColor
        if !exists { label.stringValue += "（不存在）" }
        return label
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "索引"
        panel.message = "选择要让 KongSeek 索引的文件夹"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            var roots = Preferences.roots
            for url in panel.urls where !roots.contains(url.path) { roots.append(url.path) }
            Preferences.roots = roots
            self.indexSettingsChanged()
        }
    }

    @objc private func removeFolder() {
        let row = folderTable.selectedRow
        guard row >= 0 && row < folders.count else { return }
        var roots = Preferences.roots
        roots.removeAll { $0 == folders[row] }
        Preferences.roots = roots
        indexSettingsChanged()
    }

    @objc private func resetFolders() {
        Preferences.resetRoots()
        indexSettingsChanged()
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        switch sender {
        case hiddenCheckbox:
            Preferences.includeHidden = sender.state == .on
            indexSettingsChanged()
        case pathCheckbox:
            Preferences.matchFolderPath = sender.state == .on
        case archiveCheckbox:
            Preferences.archiveSearch = sender.state == .on
            onArchiveSettingsChange()
        case loginCheckbox:
            do {
                if sender.state == .on {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "无法更改登录启动设置"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        default:
            break
        }
        refresh()
    }

    @objc private func rebuildIndex() {
        onRebuild()
        refresh()
    }

    @objc private func scanArchives() {
        onArchiveSettingsChange()
        refresh()
    }

    private func indexSettingsChanged() {
        onIndexSettingsChange()
        refresh()
    }

    // MARK: - Clipboard tab

    private func buildClipboardView() -> NSView {
        let content = NSView()
        let shortcutLabel = NSTextField(labelWithString: "打开剪贴板历史：")
        clipRecorder.onRecord = { [weak self] shortcut in
            guard let self else { return }
            Preferences.clipboardShortcut = shortcut
            self.clipboardHotKey.register(shortcut)
            self.refresh()
            self.onClipboardSettingsChange()
        }
        clipRecorder.onRecordingChange = { [weak self] recording in
            if recording { self?.clipboardHotKey.suspend() } else { self?.clipboardHotKey.resume() }
        }
        clipShortcutNote.font = .systemFont(ofSize: 11)
        let retentionLabel = NSTextField(labelWithString: "保留：")
        for choice in Self.retentionChoices { clipRetentionPopup.addItem(withTitle: choice.1) }
        let countLabel = NSTextField(labelWithString: "最多：")
        for count in Self.countChoices { clipCountPopup.addItem(withTitle: "\(count) 条") }
        for popup in [clipRetentionPopup, clipCountPopup] {
            popup.target = self
            popup.action = #selector(clipboardPopupChanged(_:))
        }
        for checkbox in [clipEnabledCheckbox, autoPasteCheckbox, clipOCRCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(clipboardCheckboxChanged(_:))
        }
        accessibilityButton.target = self
        accessibilityButton.action = #selector(requestAccessibility)
        let note = NSTextField(wrappingLabelWithString: "内容只保存在这台 Mac（不参与时间机器备份）。带机密或临时标记的内容（如密码管理器复制的密码）不记录；未带标记的私密内容仍可能被记录，可随时在剪贴板窗口中暂停或删除。固定的条目不会因期限或数量被删除。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 450
        clipStatusLabel.font = .systemFont(ofSize: 11)
        clipStatusLabel.textColor = .secondaryLabelColor
        clipStatusLabel.preferredMaxLayoutWidth = 450
        let clear = NSButton(title: "清空历史（保留固定）…", target: self, action: #selector(clearClipboard))

        let views: [NSView] = [clipEnabledCheckbox, shortcutLabel, clipRecorder, clipShortcutNote, retentionLabel, clipRetentionPopup, countLabel, clipCountPopup,
                               autoPasteCheckbox, accessibilityButton, clipOCRCheckbox, note, clipStatusLabel, clear]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            clipEnabledCheckbox.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            clipEnabledCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            shortcutLabel.leadingAnchor.constraint(equalTo: clipEnabledCheckbox.leadingAnchor),
            shortcutLabel.centerYAnchor.constraint(equalTo: clipRecorder.centerYAnchor),
            clipRecorder.topAnchor.constraint(equalTo: clipEnabledCheckbox.bottomAnchor, constant: 12),
            clipRecorder.leadingAnchor.constraint(equalTo: shortcutLabel.trailingAnchor, constant: 6),
            clipRecorder.widthAnchor.constraint(equalToConstant: 150),
            clipShortcutNote.leadingAnchor.constraint(equalTo: clipRecorder.trailingAnchor, constant: 8),
            clipShortcutNote.centerYAnchor.constraint(equalTo: clipRecorder.centerYAnchor),
            clipShortcutNote.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            retentionLabel.leadingAnchor.constraint(equalTo: clipEnabledCheckbox.leadingAnchor),
            retentionLabel.centerYAnchor.constraint(equalTo: clipRetentionPopup.centerYAnchor),
            clipRetentionPopup.topAnchor.constraint(equalTo: clipRecorder.bottomAnchor, constant: 12),
            clipRetentionPopup.leadingAnchor.constraint(equalTo: retentionLabel.trailingAnchor, constant: 6),
            countLabel.leadingAnchor.constraint(equalTo: clipRetentionPopup.trailingAnchor, constant: 20),
            countLabel.centerYAnchor.constraint(equalTo: clipRetentionPopup.centerYAnchor),
            clipCountPopup.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 6),
            clipCountPopup.centerYAnchor.constraint(equalTo: clipRetentionPopup.centerYAnchor),
            autoPasteCheckbox.topAnchor.constraint(equalTo: clipRetentionPopup.bottomAnchor, constant: 14),
            autoPasteCheckbox.leadingAnchor.constraint(equalTo: clipEnabledCheckbox.leadingAnchor),
            accessibilityButton.topAnchor.constraint(equalTo: autoPasteCheckbox.bottomAnchor, constant: 4),
            accessibilityButton.leadingAnchor.constraint(equalTo: autoPasteCheckbox.leadingAnchor, constant: 18),
            clipOCRCheckbox.topAnchor.constraint(equalTo: accessibilityButton.bottomAnchor, constant: 8),
            clipOCRCheckbox.leadingAnchor.constraint(equalTo: clipEnabledCheckbox.leadingAnchor),
            note.topAnchor.constraint(equalTo: clipOCRCheckbox.bottomAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: clipEnabledCheckbox.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            clipStatusLabel.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
            clipStatusLabel.leadingAnchor.constraint(equalTo: clipEnabledCheckbox.leadingAnchor),
            clipStatusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            clear.topAnchor.constraint(equalTo: clipStatusLabel.bottomAnchor, constant: 8),
            clear.leadingAnchor.constraint(equalTo: clipEnabledCheckbox.leadingAnchor),
            clear.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -14),
        ])
        return content
    }

    private func refreshClipboard() {
        clipEnabledCheckbox.state = Preferences.clipboardEnabled ? .on : .off
        clipRecorder.shortcut = clipboardHotKey.shortcut
        if let shortcut = clipboardHotKey.shortcut, !clipboardHotKey.isRegistered {
            clipShortcutNote.stringValue = "\(shortcut.display) 已被占用（可能是 KongFetch），请换一个"
            clipShortcutNote.textColor = .systemRed
        } else {
            clipShortcutNote.stringValue = "⌫ 清除，⎋ 取消"
            clipShortcutNote.textColor = .secondaryLabelColor
        }
        clipRetentionPopup.selectItem(at: Self.retentionChoices.firstIndex { $0.0 == Preferences.clipboardRetentionDays } ?? 1)
        clipCountPopup.selectItem(at: Self.countChoices.firstIndex(of: Preferences.clipboardMaximumItems) ?? 1)
        autoPasteCheckbox.state = Preferences.autoPaste ? .on : .off
        accessibilityButton.isHidden = !Preferences.autoPaste || Paster.isTrusted
        clipOCRCheckbox.state = Preferences.clipboardOCR ? .on : .off
        let history = clipboardMonitor.history
        var parts = ["\(history.items.count) 条，" + ByteCountFormatter.string(fromByteCount: Int64(history.totalBytes), countStyle: .file)]
        if Preferences.clipboardEnabled { parts.append(Preferences.clipboardPaused ? "已暂停记录" : "正在记录") }
        if let problem = history.problem { parts.append(problem) }
        clipStatusLabel.stringValue = parts.joined(separator: " · ")
    }

    @objc private func clipboardCheckboxChanged(_ sender: NSButton) {
        switch sender {
        case clipEnabledCheckbox:
            Preferences.clipboardEnabled = sender.state == .on
            if sender.state == .on {
                Preferences.clipboardPaused = false
                clipboardMonitor.skipCurrentContents()
            }
        case autoPasteCheckbox:
            Preferences.autoPaste = sender.state == .on
            if sender.state == .on && !Paster.isTrusted { Paster.requestTrust() }
        case clipOCRCheckbox:
            Preferences.clipboardOCR = sender.state == .on
        default:
            break
        }
        refresh()
        onClipboardSettingsChange()
    }

    @objc private func clipboardPopupChanged(_ sender: NSPopUpButton) {
        if sender === clipRetentionPopup, Self.retentionChoices.indices.contains(sender.indexOfSelectedItem) {
            Preferences.clipboardRetentionDays = Self.retentionChoices[sender.indexOfSelectedItem].0
        } else if sender === clipCountPopup, Self.countChoices.indices.contains(sender.indexOfSelectedItem) {
            Preferences.clipboardMaximumItems = Self.countChoices[sender.indexOfSelectedItem]
        }
        clipboardMonitor.history.limits = Preferences.clipboardLimits
        refresh()
    }

    @objc private func requestAccessibility() {
        Paster.requestTrust()
        Paster.openAccessibilitySettings()
    }

    @objc private func clearClipboard() {
        let alert = NSAlert()
        alert.messageText = "清空剪贴板历史？"
        alert.informativeText = "未固定的条目会被删除，无法恢复。固定的条目保留。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.clipboardMonitor.history.clear(includingPinned: false)
            self?.refresh()
        }
    }

    func refresh() {
        generalPage.refresh()
        refreshClipboard()
        snippetPage.refreshStatus()
        refreshOCR()
        if folders != Preferences.roots {
            folders = Preferences.roots
            folderTable.reloadData()
        }
        hiddenCheckbox.state = Preferences.includeHidden ? .on : .off
        pathCheckbox.state = Preferences.matchFolderPath ? .on : .off
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        indexStatusLabel.stringValue = indexStatus()
        archiveCheckbox.state = Preferences.archiveSearch ? .on : .off
        archiveScanButton.isHidden = !Preferences.archiveSearch
        archiveStatusLabel.isHidden = !Preferences.archiveSearch
        archiveScanButton.isEnabled = !archives.isScanning
        archiveStatusLabel.stringValue = archives.statusText

        recorder.shortcut = hotKey.shortcut
        if let shortcut = hotKey.shortcut {
            shortcutNote.stringValue = hotKey.isRegistered
                ? "点击按钮后按下新的组合；⌫ 清除，⎋ 取消。"
                : "\(shortcut.display) 已被系统或其他应用占用，请换一个组合。"
            shortcutNote.textColor = hotKey.isRegistered ? .secondaryLabelColor : .systemRed
        } else {
            shortcutNote.stringValue = "未设快捷键，只能连按唤起或从菜单栏打开。"
            shortcutNote.textColor = .secondaryLabelColor
        }

        let trigger = Preferences.doubleTapModifier
        tapPopup.selectItem(at: TapModifier.allCases.firstIndex(of: trigger) ?? 0)
        if trigger == .off {
            tapNote.stringValue = "已关闭。"
            tapNote.textColor = .secondaryLabelColor
            permissionButton.isHidden = true
        } else if doubleTap.isListening {
            tapNote.stringValue = "快速按两下 \(trigger.title) 即可唤起，中间不要按其他键。"
            tapNote.textColor = .secondaryLabelColor
            permissionButton.isHidden = true
        } else {
            tapNote.stringValue = "需要在“系统设置 › 隐私与安全性 › 输入监控”中允许 KongSeek。授权后几秒内自动生效，无需重启。"
            tapNote.textColor = .systemOrange
            permissionButton.isHidden = false
        }
    }

    private func apply(_ shortcut: Shortcut?) {
        Preferences.searchShortcut = shortcut
        hotKey.register(shortcut)
        refresh()
    }

    @objc private func resetShortcut() {
        apply(.defaultSearch)
    }

    @objc private func tapChanged() {
        let index = tapPopup.indexOfSelectedItem
        guard TapModifier.allCases.indices.contains(index) else { return }
        let modifier = TapModifier.allCases[index]
        Preferences.doubleTapModifier = modifier
        doubleTap.trigger = modifier
        doubleTap.refresh()
        if modifier != .off && !doubleTap.hasPermission { doubleTap.requestPermission() }
        refresh()
    }

    @objc private func requestPermission() {
        doubleTap.requestPermission()
        refresh()
    }
}

/// A button that records the next key combination pressed.
final class ShortcutRecorderButton: NSButton {
    var shortcut: Shortcut? {
        didSet { if !isRecording { updateTitle() } }
    }
    var onRecord: ((Shortcut?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private(set) var isRecording = false
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        title = "请按下快捷键…"
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            if plain && event.keyCode == 53 { // Escape: cancel
                self.stopRecording()
            } else if plain && (event.keyCode == 51 || event.keyCode == 117) { // Delete: clear
                self.stopRecording()
                self.onRecord?(nil)
            } else if let shortcut = Shortcut(event: event) {
                self.stopRecording()
                self.onRecord?(shortcut)
            } else {
                NSSound.beep() // needs ⌘, ⌥ or ⌃
            }
            return nil
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        updateTitle()
        onRecordingChange?(false)
    }

    private func updateTitle() {
        title = shortcut?.display ?? "未设置"
    }
}
