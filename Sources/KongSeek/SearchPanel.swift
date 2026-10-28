import AppKit
import Quartz
import PDFKit
import UniformTypeIdentifiers
import KongSeekCore
import KongSeekText

/// A floating panel that takes keyboard input without activating KongSeek,
/// so the app the user was in stays in front.
final class SearchPanel: NSPanel, QLPreviewPanelDataSource {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The file the Quick Look panel (⌘Y) shows.
    var quickLookURL: (() -> URL?)?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        quickLookURL != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURL?() == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookURL?().map { $0 as NSURL }
    }
}

/// The search window: query field, results list, Quick Look preview, status line.
final class SearchWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let panel: SearchPanel
    private let service: IndexService
    private let ocr: OCRService
    private let field = NSTextField()
    private let table = ResultTable()
    private let preview: QLPreviewView
    /// Over the preview when the hit is on a known page of a PDF: that page, with the
    /// words marked (0.23), instead of the first page Quick Look shows.
    private let hitPreview = PDFView()
    private var hitPreviewToken = 0
    private var lastHitPreviewQuery: [String] = []
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")

    /// Full-text mode (Tab): Spotlight searches file contents.
    private var contentMode = false
    private let contentSearch = ContentSearch()
    private let modeButton = NSButton(title: "名称", target: nil, action: nil)
    /// "?": lists the search syntax with examples.
    private let helpButton = NSButton()
    /// The list shows the search history (↑ in an empty field).
    private var showingHistory = false
    private let snippetLabel = NSTextField(wrappingLabelWithString: "")
    private var snippetHeight: NSLayoutConstraint!
    private var snippetToken = 0
    /// Where the words were found in the selected file (from the passage shown above the
    /// preview), for ⌥↩ "open at the hit" and "拷贝引文" (0.18).
    private var lastHit: (path: String, page: Int?)?
    private var pendingContentSearch: DispatchWorkItem?
    /// The full-text search in progress: Spotlight results and recognized-text
    /// (OCR) results arrive separately and are merged.
    private var contentToken = 0
    private var spotlightItems: [ResultItem] = []
    private var spotlightFinished = false
    private var ocrItems: [ResultItem] = []
    private var contentQuery = SearchQuery("")
    /// Web search rows shown above the results ("hd 仁").
    private var webRows: [ResultItem] = []
    private let definitionScroll = NSTextView.scrollableTextView()
    private var definitionView: NSTextView { definitionScroll.documentView as! NSTextView }
    private var results: [ResultItem] = []
    private var outcome = SearchOutcome()
    private var keyMonitor: Any?
    private let icons = NSCache<NSString, NSImage>()
    private let backButton = NSButton()
    private let scrollView = NSScrollView()
    private let actions = ResultActions()
    /// Opens the batch-rename window with these files.
    /// Opens the file list window for a search (0.19).
    var onFileList: ((FileListSource) -> Void)?
    var onBatchRename: (([URL]) -> Void)?
    /// Files taken out of archives for the preview, by "archive\0inner".
    private var archivePreviews: [String: URL] = [:]
    private var archivePreviewToken = 0
    /// Name-mode passages are looked up one at a time.
    private let snippetQueue = DispatchQueue(label: "KongSeek.snippet", qos: .userInitiated)
    private let defaultPlaceholder = "搜索文件名、拼音或首字母   ext:pdf  in:文件夹  dm:7d  size:>10mb  -排除"

    /// Folder being browsed (→ on a folder), and the states to return to.
    private struct BrowseLevel {
        let folder: String?
        let text: String
        let outcome: SearchOutcome
        let selection: Int
        let scroll: NSPoint
    }
    private var browsedFolder: String?
    private var browseStack: [BrowseLevel] = []

    /// When the panel was last shown, and how often it took focus back since then.
    private var shownAt = Date.distantPast
    private var focusReclaims = 0

    private static let width: CGFloat = 800
    private static let height: CGFloat = 500

    init(service: IndexService, ocr: OCRService) {
        self.service = service
        self.ocr = ocr
        panel = SearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        preview = QLPreviewView(frame: .zero, style: .compact)
        super.init()
        configurePanel()
        buildLayout()
        panel.quickLookURL = { [weak self] in self?.selectedItem.flatMap { self?.previewURL(for: $0) } }
    }

    // MARK: - Showing

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let origin = NSPoint(x: frame.midX - Self.width / 2, y: frame.minY + frame.height * 0.62 - Self.height / 2)
            panel.setFrameOrigin(origin)
        }
        updateStatus()
        shownAt = Date()
        focusReclaims = 0
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        installKeyMonitor()
        runSearch() // an empty query lists recently opened items
    }

    /// Opens the window with `query` typed in (menu bar › 最近下载 › 在搜索窗口中查看).
    func show(query: String) {
        show()
        field.stringValue = query
        field.currentEditor()?.moveToEndOfDocument(nil)
        runSearch()
    }

    func hide() {
        contentSearch.stop()
        pendingContentSearch?.cancel()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        resetBrowsing()
        removeKeyMonitor()
        preview.previewItem = nil
        hideHitPreview()
        panel.orderOut(nil)
    }

    /// Hides the panel when the user moves to another window. Right after it is
    /// shown, macOS can hand keyboard focus straight back to the app that was in
    /// front (seen on the first ⌥Space after launch); the panel then takes focus
    /// back instead of disappearing.
    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        // A sheet (naming a saved search) takes focus; stay.
        if panel.attachedSheet != nil { return }
        // Quick Look (⌘Y) takes focus while it is open; stay until it closes.
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
        if Date().timeIntervalSince(shownAt) < 0.8 && focusReclaims < 3 {
            focusReclaims += 1
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
                self.panel.makeKeyAndOrderFront(nil)
                self.panel.makeFirstResponder(self.field)
                self.field.currentEditor()?.moveToEndOfDocument(nil)
            }
            return
        }
        // Let a focus change settle (e.g. Quick Look's preview briefly taking it).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow, self.panel.attachedSheet == nil else { return }
            // Quick Look (⌘Y) takes focus while it is open; stay until it closes.
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
            self.hide()
        }
    }

    // MARK: - Setup

    private func configurePanel() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.delegate = self
    }

    private func buildLayout() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        let searchIcon = backButton
        searchIcon.isBordered = false
        searchIcon.bezelStyle = .regularSquare
        searchIcon.imagePosition = .imageOnly
        searchIcon.target = self
        searchIcon.action = #selector(goBack)
        searchIcon.contentTintColor = .secondaryLabelColor
        updateBackButton()

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.placeholderString = defaultPlaceholder
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true

        let topLine = NSBox()
        topLine.boxType = .separator
        let bottomLine = NSBox()
        bottomLine.boxType = .separator
        let middleLine = NSBox()
        middleLine.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 46
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onContextMenu = { [weak self] row, point in
            guard let self, self.results.indices.contains(row), !self.results[row].isHeader else { return }
            self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if let fill = self.results[row].fill, fill.isSaved {
                self.showSavedSearchMenu(fill.text, at: point)
            } else {
                self.showActionMenu(at: point)
            }
        }
        table.refusesFirstResponder = true

        let scroll = scrollView
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        preview.shouldCloseWithWindow = false
        preview.autostarts = true

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        // The shortcuts below the list are also buttons, for the mouse (0.22).
        func hint(_ title: String, _ action: Selector, _ tip: String) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .recessed
            button.showsBorderOnlyWhileMouseInside = true
            button.controlSize = .small
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            button.toolTip = tip
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return button
        }
        let hints = NSStackView(views: [
            hint("↩ 打开", #selector(hintOpen), "打开所选（双击也可以）"),
            hint("→ 进入文件夹", #selector(hintEnterFolder), "浏览所选文件夹的内容"),
            hint("⌘↩ 在访达中显示", #selector(hintReveal), "在访达中显示所选"),
            hint("⌘Y 快速查看", #selector(hintQuickLook), "快速查看所选"),
            hint("⌘K 更多操作", #selector(hintActions), "更多操作（右键单击结果也可以）"),
            hint("⌘S 收藏搜索", #selector(hintSave), "收藏当前搜索"),
            hint("? 语法", #selector(showSyntaxHelpFromButton), "搜索语法速查"),
        ])
        hints.spacing = 2
        hints.setHuggingPriority(.defaultHigh, for: .horizontal)
        hints.detachesHiddenViews = true

        modeButton.bezelStyle = .recessed
        modeButton.setButtonType(.momentaryPushIn)
        modeButton.font = .systemFont(ofSize: 12, weight: .medium)
        modeButton.target = self
        modeButton.action = #selector(toggleMode)
        helpButton.isBordered = false
        helpButton.bezelStyle = .regularSquare
        helpButton.imagePosition = .imageOnly
        helpButton.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "搜索语法")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        helpButton.contentTintColor = .secondaryLabelColor
        helpButton.toolTip = "搜索语法与例子（也可输入 ?）"
        helpButton.target = self
        helpButton.action = #selector(showSyntaxHelpFromButton)
        modeButton.toolTip = "⇥ 切换按名称 / 按内容（全文）搜索"
        snippetLabel.font = .systemFont(ofSize: 12)
        snippetLabel.textColor = .labelColor
        snippetLabel.maximumNumberOfLines = 5
        snippetLabel.isSelectable = true
        snippetLabel.lineBreakMode = .byTruncatingTail

        definitionView.isEditable = false
        definitionView.isSelectable = true
        definitionView.drawsBackground = false
        definitionView.font = .systemFont(ofSize: 14)
        definitionView.textContainerInset = NSSize(width: 10, height: 10)
        definitionScroll.drawsBackground = false
        definitionScroll.hasVerticalScroller = true
        definitionScroll.isHidden = true
        hitPreview.autoScales = true
        hitPreview.displayMode = .singlePageContinuous
        hitPreview.displaysPageBreaks = true
        hitPreview.backgroundColor = .windowBackgroundColor
        hitPreview.isHidden = true

        for view in [searchIcon, field, helpButton, modeButton, topLine, scroll, middleLine, snippetLabel, preview, hitPreview, definitionScroll, emptyLabel, bottomLine, statusLabel, hints] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hints.setClippingResistancePriority(.defaultLow - 1, for: .horizontal)

        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            searchIcon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 22),

            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: helpButton.leadingAnchor, constant: -8),
            helpButton.trailingAnchor.constraint(equalTo: modeButton.leadingAnchor, constant: -8),
            helpButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            helpButton.widthAnchor.constraint(equalToConstant: 22),
            modeButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            modeButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            modeButton.widthAnchor.constraint(equalToConstant: 52),
            field.heightAnchor.constraint(equalToConstant: 30),

            topLine.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            topLine.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: background.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scroll.widthAnchor.constraint(equalToConstant: 440),
            scroll.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),

            middleLine.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            middleLine.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            middleLine.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 6),
            middleLine.widthAnchor.constraint(equalToConstant: 1),

            snippetLabel.topAnchor.constraint(equalTo: topLine.bottomAnchor, constant: 8),
            snippetLabel.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 4),
            snippetLabel.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -4),
            preview.topAnchor.constraint(equalTo: snippetLabel.bottomAnchor, constant: 0),
            preview.leadingAnchor.constraint(equalTo: middleLine.trailingAnchor, constant: 8),
            preview.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            preview.bottomAnchor.constraint(equalTo: bottomLine.topAnchor, constant: -8),

            hitPreview.topAnchor.constraint(equalTo: preview.topAnchor),
            hitPreview.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
            hitPreview.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            hitPreview.trailingAnchor.constraint(equalTo: preview.trailingAnchor),

            definitionScroll.topAnchor.constraint(equalTo: preview.topAnchor),
            definitionScroll.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
            definitionScroll.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            definitionScroll.trailingAnchor.constraint(equalTo: preview.trailingAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),

            bottomLine.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -28),

            statusLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: background.bottomAnchor, constant: -14),
            hints.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 12),
            hints.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            hints.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
        ])
        snippetHeight = snippetLabel.heightAnchor.constraint(equalToConstant: 0)
        snippetHeight.isActive = true
        updateEmptyLabel()
    }

    // MARK: - Searching

    func controlTextDidChange(_ obj: Notification) {
        // Wait while a Chinese input method is still composing.
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        if contentMode && browsedFolder == nil {
            // Spotlight queries cost more than the name index: wait for a pause in typing.
            pendingContentSearch?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.runSearch() }
            pendingContentSearch = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            return
        }
        runSearch()
    }

    /// "cd 仁": the definition from the Dictionary app's dictionaries, plus 汉典.
    private func showLookup(_ word: String) {
        let definition = DictionaryLookup.definition(of: word) ?? ""
        webRows = [ResultItem(path: "dict:" + word, name: word, isFolder: false, score: 0, definition: definition)]
        if let handian = Preferences.quickLinks.first(where: { $0.keyword == "hd" }), let row = ResultItem.web(handian, query: word) {
            webRows.append(row)
        }
        var lookup = SearchOutcome()
        lookup.notes = ["查词"]
        show(lookup)
    }

    /// Opens the window looking up `text` (⌃⌥D on a selection).
    func showLookup(text: String?) {
        let word = (text ?? "").split(whereSeparator: \.isNewline).first.map { String($0.prefix(60)) }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if contentMode { toggleMode() }
        show()
        field.stringValue = DictionaryLookup.keyword + " " + word
        field.currentEditor()?.moveToEndOfDocument(nil)
        runSearch()
    }

    @objc private func toggleMode() {
        guard browsedFolder == nil else { return }
        contentMode.toggle()
        modeButton.title = contentMode ? "全文" : "名称"
        modeButton.contentTintColor = contentMode ? .controlAccentColor : nil
        field.placeholderString = contentMode ? "搜索文件内容：PDF、Word、Pages、文本……（Spotlight）" : defaultPlaceholder
        snippetHeight.constant = contentMode ? 92 : 0
        if !contentMode { contentSearch.stop() }
        runSearch()
    }

    private func runContentSearch() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = SearchQuery(text)
        guard let queryString = SpotlightQuery.content(for: query) else {
            contentToken += 1
            contentSearch.stop()
            var empty = SearchOutcome()
            empty.isContent = true
            empty.notes = query.valid ? ["全文搜索需要至少一个词"] : query.notes
            show(empty)
            return
        }
        let rules = Preferences.rules
        let roots = NameIndex.effectiveRoots(Preferences.roots, rules: rules)
        let ocrRoots = roots + Preferences.ocrFolders.map(Paths.canonical)
        let excluded = query.excluded.map(SearchText.fold)
        contentToken += 1
        let token = contentToken
        contentQuery = query
        spotlightItems = []
        spotlightFinished = false
        ocrItems = []

        // Recognized text of scans, searched in memory off the main thread.
        let store = ocr.store
        let needles = query.highlightWords
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hits = store.search(needles, limit: 300) { path in
                !rules.excludes(path: path, roots: ocrRoots)
            }
            let items = hits.compactMap { hit -> ResultItem? in
                let name = (hit.path as NSString).lastPathComponent
                let folded = SearchText.fold(name)
                guard !excluded.contains(where: { folded.contains($0) }), Self.accepts(name: folded, query: query),
                      query.acceptsExternal(path: hit.path, isFolder: false) else { return nil }
                if query.needsMetadata && !query.acceptsMetadata(EntryMetadata.read(path: hit.path)) { return nil }
                return ResultItem(path: hit.path, name: name, isFolder: false, score: 0, recognized: true)
            }
            DispatchQueue.main.async {
                guard let self, token == self.contentToken else { return }
                self.ocrItems = items
                self.publishContent()
            }
        }

        let started = contentSearch.search(queryString, scopes: roots) { [weak self] hits, finished in
            guard let self, token == self.contentToken else { return }
            self.spotlightItems = hits.filter { hit in
                guard !rules.excludes(path: hit.path, roots: roots),
                      query.advanced.acceptsPath(hit.path, isFolder: hit.isFolder) else { return false }
                let name = SearchText.fold((hit.path as NSString).lastPathComponent)
                return !excluded.contains { name.contains($0) }
            }.sorted { a, b in
                if a.relevance != b.relevance { return a.relevance > b.relevance }
                return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            }.map { hit in
                ResultItem(path: hit.path, name: (hit.path as NSString).lastPathComponent, isFolder: hit.isFolder, score: Int(hit.relevance * 1000))
            }
            self.spotlightFinished = finished
            self.publishContent()
        }
        if !started {
            spotlightFinished = true
            publishContent(note: "无法启动 Spotlight 搜索")
        }
    }

    /// Shows scans whose recognized text matches first, then Spotlight's results.
    private func publishContent(note: String? = nil) {
        let query = contentQuery
        var seen = Set(ocrItems.map(\.path))
        let merged = ocrItems + spotlightItems.filter { seen.insert($0.path).inserted }
        var outcome = SearchOutcome(highlightWords: query.highlightWords, notes: query.descriptions + query.natural.descriptions + (note.map { [$0] } ?? []))
        outcome.isContent = true
        outcome.gathering = !spotlightFinished
        outcome.matchCount = merged.count
        outcome.items = Array(merged.prefix(200))
        show(outcome)
    }

    /// The ext: and -ext: parts of a query, for results that did not come from Spotlight.
    private static func accepts(name foldedName: String, query: SearchQuery) -> Bool {
        if !query.extensions.isEmpty && !query.extensions.contains(where: { foldedName.hasSuffix("." + $0) }) { return false }
        return !query.excludedExtensions.contains { foldedName.hasSuffix("." + $0) }
    }

    func runSearch() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        webRows = []
        showingHistory = false
        if browsedFolder == nil && (text == "?" || text == "？") {
            contentToken += 1
            contentSearch.stop()
            showSyntaxHelp()
            return
        }
        if browsedFolder == nil, let word = DictionaryLookup.word(in: field.stringValue) {
            contentToken += 1
            contentSearch.stop()
            showLookup(word)
            return
        }
        if browsedFolder == nil, let match = QuickLinks.match(field.stringValue, in: Preferences.quickLinks),
           let row = ResultItem.web(match.link, query: match.query) {
            webRows = [row]
        }
        if contentMode && browsedFolder == nil && !text.isEmpty {
            runContentSearch()
            return
        }
        contentToken += 1
        contentSearch.stop()
        if let folder = browsedFolder {
            service.browse(folder: folder, filter: field.stringValue) { [weak self] outcome in
                self?.show(outcome)
            }
            return
        }
        service.search(field.stringValue, precision: Preferences.precision) { [weak self] outcome in
            self?.show(outcome)
        }
    }

    private func show(_ newOutcome: SearchOutcome) {
        // While Spotlight is still delivering results, keep the user's selection.
        let keepPath = newOutcome.isContent && outcome.isContent ? selectedItem?.path : nil
        let previousRow = table.selectedRow
        outcome = newOutcome
        results = webRows + newOutcome.items
        // An empty field lists saved searches above recently opened items.
        if newOutcome.isRecentList && browsedFolder == nil { results = savedSearchRows + results }
        // Nothing found: offer the web searches marked as fallbacks.
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if results.isEmpty && browsedFolder == nil && !query.isEmpty && !newOutcome.gathering && !newOutcome.isRecentList {
            results = Preferences.quickLinks.filter(\.fallback).compactMap { ResultItem.web($0, query: query) }
        }
        if Preferences.groupByFolder && browsedFolder == nil && !newOutcome.isRecentList && !query.isEmpty {
            results = Self.groupedByFolder(results)
        }
        table.reloadData()
        if let keepPath, let row = results.firstIndex(where: { $0.path == keepPath && !$0.isHeader }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if row != previousRow { table.scrollRowToVisible(row) }
        } else if let first = results.firstIndex(where: { !$0.isHeader }) {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        updatePreview()
        updateEmptyLabel()
        updateStatus()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    func indexStateChanged() {
        updateStatus()
        updateEmptyLabel()
        // A finished build may answer a query typed while it was running.
        if isVisible, case .ready = service.state, results.isEmpty, !field.stringValue.isEmpty { runSearch() }
    }

    private func updateEmptyLabel() {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        emptyLabel.isHidden = !results.isEmpty
        if outcome.isContent {
            emptyLabel.stringValue = outcome.gathering ? "正在用 Spotlight 搜索文件内容…" : "没有文件的正文包含这些词\n（只搜 Spotlight 已建立内容索引的文件）"
            return
        }
        if contentMode && text.isEmpty && results.isEmpty {
            emptyLabel.stringValue = "全文模式：输入正文中的字词\n可配合 ext:pdf、文档、最近一周 等筛选\n⇥ 切回按名称搜索"
            return
        }
        if browsedFolder != nil {
            emptyLabel.stringValue = outcome.folderNotIndexed
                ? "这个文件夹不在索引中（如应用包内部或排除的文件夹）。\n按 ⌘O 在访达中打开，← 返回。"
                : (text.isEmpty ? "文件夹是空的" : "文件夹中没有匹配的项目")
            return
        }
        switch service.state {
        case .loading where !text.isEmpty:
            emptyLabel.stringValue = "正在载入索引…"
        case .building(let entries) where !text.isEmpty && !service.searchableWhileBuilding:
            emptyLabel.stringValue = "正在建立索引，已收录 \(entries.formatted()) 项。\n首次建立需要一点时间，之后启动即可直接搜索。"
        default:
            emptyLabel.stringValue = text.isEmpty
                ? "输入文件名、拼音全拼或首字母\n例如 lunyu、ly、论语 ext:pdf\n用 KongSeek 打开过的文件会列在这里"
                : "没有找到匹配的文件"
        }
    }

    private func updateStatus() {
        var parts: [String] = []
        switch service.state {
        case .loading:
            parts.append("正在载入索引")
        case .building(let entries):
            let estimate = service.buildEstimate
            if estimate > 0 {
                let percent = min(99, entries * 100 / estimate)
                parts.append("正在重建索引 \(percent)%（\(entries.formatted()) / 约 \(estimate.formatted()) 项），期间照常搜索")
            } else {
                parts.append("正在建立索引 · \(entries.formatted()) 项")
            }
        case .ready(let entries, _):
            parts.append("已索引 \(entries.formatted()) 项")
        }
        if outcome.isContent {
            parts = ["全文（Spotlight）"]
            if outcome.gathering {
                parts.append("正在搜索… 已找到 \(outcome.matchCount.formatted()) 项")
            } else {
                let shown = results.count < outcome.matchCount ? "显示前 \(results.count) 项" : "\(results.count) 项"
                parts.append("匹配 \(outcome.matchCount.formatted()) 项，\(shown)")
            }
        } else if let folder = browsedFolder {
            parts = ["📁 " + (folder as NSString).abbreviatingWithTildeInPath, "\(outcome.matchCount.formatted()) 项", "← 返回  ⎋ 回到搜索结果"]
        } else if outcome.isRecentList {
            if !results.isEmpty { parts.append("最近打开 \(results.count) 项 · ⌘⌫ 从列表移除") }
        } else if !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            let shown = results.count < outcome.matchCount ? "显示前 \(results.count) 项" : "\(results.count) 项"
            parts.append("匹配 \(outcome.matchCount.formatted()) 项，\(shown)")
        }
        parts += outcome.notes
        statusLabel.stringValue = parts.joined(separator: " · ")
    }

    // MARK: - Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let fieldEmpty = field.stringValue.isEmpty
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            toggleMode()
        case #selector(NSResponder.moveUp(_:)):
            // ↑ in an empty field (at the top of the list) shows the search history.
            if fieldEmpty && browsedFolder == nil && !showingHistory && table.selectedRow <= 0 && !Preferences.searchHistory.isEmpty {
                showHistory()
            } else {
                moveSelection(by: -1)
            }
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            if let item = selectedItem, item.isFolder { enterFolder(item) } else { openSelected() }
        case #selector(NSResponder.moveRight(_:)):
            // → at the end of the text enters the selected folder.
            let selection = textView.selectedRange()
            guard let item = selectedItem, item.isFolder, selection.length == 0, selection.location == (textView.string as NSString).length else { return false }
            enterFolder(item)
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.deleteBackward(_:)):
            guard browsedFolder != nil, fieldEmpty else { return false }
            goBack()
        case #selector(NSResponder.cancelOperation(_:)):
            if browsedFolder != nil {
                leaveBrowsing()
            } else if fieldEmpty {
                hide()
            } else {
                field.stringValue = ""
                runSearch()
            }
        default:
            return false
        }
        return true
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleShortcut(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// ⌘-shortcuts, which the text field would otherwise take for itself.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let keyCode = event.keyCode
        if modifiers == [.option], keyCode == 36 || keyCode == 76 {
            // ⌥↩: open at the page / slide of the hit.
            if let item = selectedItem, item.isFile, !item.isFolder, !item.isInArchive {
                openAtHit(item)
                return true
            }
        }
        if modifiers == [.command] {
            switch keyCode {
            case 36, 76: // Return, Enter
                revealSelected()
                return true
            case 51: // ⌘⌫: remove from the recent list, or move to the Trash
                guard let item = selectedItem else { return false }
                if let fill = item.fill {
                    if fill.isSaved {
                        Preferences.savedSearches.removeAll { $0 == fill.text }
                        Preferences.savedSearchNames[fill.text] = nil
                        statusLabel.stringValue = "已从收藏中移除“\(fill.text)”"
                        runSearch()
                    } else if fill.isHistory {
                        Preferences.searchHistory.removeAll { $0 == fill.text }
                        if Preferences.searchHistory.isEmpty { runSearch() } else { showHistory() }
                    }
                    return true
                }
                if outcome.isRecentList {
                    Preferences.forget(item.path)
                    runSearch()
                } else {
                    trash(item)
                }
                return true
            case 6: // ⌘Z: put back what was just moved to the Trash
                guard actions.canUndoTrash else { return false }
                statusLabel.stringValue = actions.undoTrash()
                return true
            case 1: // ⌘S: save this search
                saveCurrentSearch()
                return true
            case 5: // ⌘G: group results by folder
                Preferences.groupByFolder.toggle()
                let keep = selectedItem?.path
                show(outcome)
                if let keep, let row = results.firstIndex(where: { $0.path == keep && !$0.isHeader }) {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    table.scrollRowToVisible(row)
                }
                statusLabel.stringValue = Preferences.groupByFolder ? "已按文件夹分组（⌘G 取消）" : "已取消按文件夹分组"
                return true
            case 31: // ⌘O: open (folders in Finder)
                openSelected()
                return true
            case 40: // ⌘K: action menu (for a saved search: name it or remove it)
                if let fill = selectedItem?.fill, fill.isSaved { showSavedSearchMenu(fill.text) } else { showActionMenu() }
                return true
            case 16: // ⌘Y: Quick Look
                toggleQuickLook()
                return true
            case 125: // ⌘↓: enter folder
                if let item = selectedItem, item.isFolder { enterFolder(item) }
                return true
            case 126: // ⌘↑: back
                goBack()
                return true
            case 8: // C: copy the file unless text is selected in the field
                if let editor = field.currentEditor(), editor.selectedRange.length > 0 { return false }
                copySelected(asPath: false)
                return true
            default:
                if let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...9).contains(digit) {
                    let rows = selectableRows
                    if digit - 1 < rows.count { open(row: rows[digit - 1]) }
                    return true
                }
            }
        }
        if modifiers == [.command, .option], keyCode == 8 {
            copySelected(asPath: true)
            return true
        }
        if modifiers == [.command, .shift], keyCode == 8, let item = selectedItem {
            statusLabel.stringValue = actions.copy(item, as: .name)
            return true
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = table.selectedRow
        var next = max(0, min(results.count - 1, (current < 0 ? 0 : current + delta)))
        // Folder headings are skipped (⌘G).
        while results.indices.contains(next) && results[next].isHeader { next += delta < 0 ? -1 : 1 }
        guard results.indices.contains(next) else {
            // Moving up onto the first heading: show it, keep the selection.
            if delta < 0 { table.scrollRowToVisible(0) }
            return
        }
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
        if delta < 0 && next > 0 && results[next - 1].isHeader { table.scrollRowToVisible(next - 1) }
    }

    /// Rows that can be selected, in order (results without folder headings); ⌘1…⌘9 count these.
    private var selectableRows: [Int] { results.indices.filter { !results[$0].isHeader } }

    /// Files grouped under a heading per folder (⌘G): folders in the order of their
    /// best match, files within a folder keeping their order. Other rows (web
    /// searches, examples) stay on top.
    static func groupedByFolder(_ items: [ResultItem]) -> [ResultItem] {
        let others = items.filter { !$0.isFile }
        var order: [String] = []
        var members: [String: [ResultItem]] = [:]
        for item in items where item.isFile {
            let folder = (item.path as NSString).deletingLastPathComponent
            if members[folder] == nil { order.append(folder) }
            members[folder, default: []].append(item)
        }
        var result = others
        for folder in order {
            let files = members[folder] ?? []
            result.append(ResultItem(path: "header:" + folder, name: displayLocation(of: folder + "/x"), isFolder: true, score: files.count, isHeader: true))
            result += files
        }
        return result
    }

    // MARK: - Actions

    private var selectedItem: ResultItem? {
        let row = table.selectedRow
        return row >= 0 && row < results.count ? results[row] : nil
    }

    @objc func openSelected() {
        open(row: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow)
    }

    private func open(row: Int) {
        guard row >= 0 && row < results.count, !results[row].isHeader else { return }
        let item = results[row]
        if let fill = item.fill {
            apply(fill)
            return
        }
        rememberSearch()
        if let link = item.link {
            hide()
            NSWorkspace.shared.open(link)
            return
        }
        if item.definition != nil {
            hide()
            DictionaryLookup.openInDictionaryApp(item.name)
            return
        }
        if item.isInArchive {
            openFromArchive(item)
            return
        }
        hide()
        actions.open(item)
    }

    private func revealSelected() {
        guard let item = selectedItem, item.isFile else { return }
        rememberSearch()
        hide()
        actions.reveal(archiveOrSelf(item))
    }

    // MARK: - Files inside archives

    private static func archiveKey(_ item: ResultItem) -> String {
        item.path + "\u{0}" + (item.innerPath ?? "")
    }

    /// The archive itself, for actions that work on the .zip (reveal).
    private func archiveOrSelf(_ item: ResultItem) -> ResultItem {
        guard item.isInArchive else { return item }
        return ResultItem(path: item.path, name: (item.path as NSString).lastPathComponent, isFolder: false, score: item.score)
    }

    /// What the preview and Quick Look show: the file itself, or for a file in an
    /// archive its extracted copy (the archive until that is ready).
    private func previewURL(for item: ResultItem) -> URL? {
        guard item.isFile else { return nil }
        if item.isInArchive, let extracted = archivePreviews[Self.archiveKey(item)] { return extracted }
        return URL(fileURLWithPath: item.path)
    }

    private func openFromArchive(_ item: ResultItem) {
        guard let inner = item.innerPath else { return }
        statusLabel.stringValue = "正在从压缩包中取出“\(item.name)”…"
        ArchiveService.extract(inner: inner, from: item.path) { [weak self] result in
            switch result {
            case .success(let url):
                self?.hide()
                NSWorkspace.shared.open(url)
            case .failure(let error):
                self?.statusLabel.stringValue = "无法从压缩包中取出：\(error.localizedDescription)"
            }
        }
    }

    private func copyFromArchive(_ item: ResultItem, as kind: ResultActions.CopyKind) {
        guard let inner = item.innerPath else { return }
        switch kind {
        case .name:
            statusLabel.stringValue = actions.copy(item, as: .name)
        case .path:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path + "/" + inner, forType: .string)
            statusLabel.stringValue = "已拷贝压缩包内路径：\((item.path as NSString).lastPathComponent)/\(inner)"
        case .file:
            statusLabel.stringValue = "正在从压缩包中取出“\(item.name)”…"
            ArchiveService.extract(inner: inner, from: item.path) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.statusLabel.stringValue = self.actions.copy(ResultItem(path: url.path, name: item.name, isFolder: false, score: 0), as: .file)
                case .failure(let error):
                    self.statusLabel.stringValue = "无法从压缩包中取出：\(error.localizedDescription)"
                }
            }
        }
    }

    /// Extracts the selected archive entry in the background for the preview (up to 200 MB).
    private func loadArchivePreview(_ item: ResultItem) {
        archivePreviewToken += 1
        let token = archivePreviewToken
        let key = Self.archiveKey(item)
        guard let inner = item.innerPath, archivePreviews[key] == nil else { return }
        ArchiveService.extract(inner: inner, from: item.path, maximumSize: 200_000_000) { [weak self] result in
            guard let self, case .success(let url) = result else { return }
            if self.archivePreviews.count > 200 { self.archivePreviews.removeAll() }
            self.archivePreviews[key] = url
            guard token == self.archivePreviewToken, self.selectedItem.map(Self.archiveKey) == key else { return }
            self.preview.previewItem = url as NSURL
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        }
    }

    private func copySelected(asPath: Bool) {
        guard let item = selectedItem else { return }
        if !item.isFile {
            let text = item.definition.flatMap { $0.isEmpty ? nil : $0 } ?? item.link?.absoluteString ?? item.name
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            statusLabel.stringValue = item.definition != nil ? "已拷贝释义" : "已拷贝网址"
            return
        }
        if item.isInArchive {
            copyFromArchive(item, as: asPath ? .path : .file)
            return
        }
        statusLabel.stringValue = actions.copy(item, as: asPath ? .path : .file)
    }

    private func trash(_ item: ResultItem) {
        guard item.isFile else { return }
        if item.isInArchive {
            statusLabel.stringValue = "这是压缩包中的文件，不能单独移到废纸篓"
            return
        }
        statusLabel.stringValue = actions.moveToTrash(item)
        if let row = results.firstIndex(of: item) {
            results.remove(at: row)
            outcome.items = results
            table.removeRows(at: IndexSet(integer: row), withAnimation: .effectFade)
            if !results.isEmpty {
                table.selectRowIndexes(IndexSet(integer: min(row, results.count - 1)), byExtendingSelection: false)
            }
            updatePreview()
            updateEmptyLabel()
        }
    }

    // MARK: - Buttons below the list (0.22)

    @objc private func hintOpen() { openSelected() }

    @objc private func hintEnterFolder() {
        if let item = selectedItem, item.isFolder { enterFolder(item) } else { statusLabel.stringValue = "先选中一个文件夹" }
    }

    @objc private func hintReveal() { revealSelected() }
    @objc private func hintQuickLook() { toggleQuickLook() }

    @objc private func hintActions() {
        if let fill = selectedItem?.fill, fill.isSaved { showSavedSearchMenu(fill.text) } else { showActionMenu() }
    }

    @objc private func hintSave() { saveCurrentSearch() }

    private func toggleQuickLook() {
        guard let item = selectedItem, item.isFile else { return }
        let quickLook = QLPreviewPanel.shared()!
        if quickLook.isVisible {
            quickLook.orderOut(nil)
        } else {
            quickLook.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Syntax help and saved searches

    @objc private func showSyntaxHelpFromButton() {
        if field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { field.stringValue = "?" }
        panel.makeFirstResponder(field)
        field.currentEditor()?.moveToEndOfDocument(nil)
        showSyntaxHelp()
    }

    private func showSyntaxHelp() {
        var help = SearchOutcome(items: SyntaxHelp.rows)
        help.notes = ["搜索语法：单击或按 ↩ 把例子加入搜索框（可组合多条，如 合同 ext:pdf dm:thisyear）"]
        help.matchCount = help.items.count
        show(help)
        statusLabel.stringValue = help.notes[0]
    }

    /// Puts a saved search or a syntax example into the field and searches.
    private func apply(_ fill: QueryFill) {
        var base = field.stringValue.trimmingCharacters(in: .whitespaces)
        if fill.replace || base == "?" || base == "？" { base = "" }
        let prefix = base.isEmpty ? "" : base + " "
        // Without a value to type over, leave the caret after a space, ready for the next word.
        let text = prefix + fill.text + (fill.select == nil && !fill.isSaved && !fill.isHistory ? " " : "")
        field.stringValue = text
        panel.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let whole = text as NSString
            var range = NSRange(location: whole.length, length: 0)
            if let sample = fill.select {
                let found = whole.range(of: sample, options: .backwards)
                if found.location != NSNotFound { range = found }
            }
            editor.selectedRange = range
        }
        runSearch()
    }

    /// Searches that led somewhere: remembered when a result is opened or revealed.
    private func rememberSearch() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Preferences.keepSearchHistory, browsedFolder == nil, !text.isEmpty, text != "?", text != "？" else { return }
        var history = Preferences.searchHistory
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        Preferences.searchHistory = history
    }

    private func showHistory() {
        let rows = Preferences.searchHistory.map { text in
            ResultItem(path: "history:" + text, name: text, isFolder: false, score: 0,
                       fill: QueryFill(text: text, replace: true, select: nil, explanation: "搜索历史", isHistory: true))
        }
        var history = SearchOutcome(items: rows)
        history.matchCount = rows.count
        show(history)
        showingHistory = true
        statusLabel.stringValue = "搜索历史：↑↓ 选择，↩ 再次搜索，⌘⌫ 删除一条"
    }

    private var savedSearchRows: [ResultItem] {
        let names = Preferences.savedSearchNames
        return Preferences.savedSearches.map { text in
            ResultItem(path: "saved:" + text, name: names[text] ?? text, isFolder: false, score: 0,
                       fill: QueryFill(text: text, replace: true, select: nil, explanation: names[text] == nil ? "收藏的搜索" : "收藏的搜索：\(text)", isSaved: true))
        }
    }

    /// ⌘K on a saved search: name it (a course, a project), or remove it (0.19).
    private func showSavedSearchMenu(_ text: String, at point: NSPoint? = nil) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: Preferences.savedSearchNames[text] == nil ? "命名…" : "重命名…", key: "") { [weak self] in
            self?.askName(for: text)
        })
        menu.addItem(ClosureMenuItem(title: "把结果放入文件清单", key: "") { [weak self] in
            self?.hide()
            self?.onFileList?(.query(text))
        })
        menu.addItem(ClosureMenuItem(title: "打包课程材料（复制到文件夹或 zip）…", key: "") { [weak self] in
            guard let self else { return }
            let name = Preferences.savedSearchNames[text] ?? text
            self.hide()
            self.service.search(text, precision: Preferences.precision, limit: 3_000) { outcome in
                let paths = outcome.items.filter { $0.isFile && !$0.isFolder && !$0.isInArchive }.map(\.path)
                CoursePackageWindowController.shared.start(paths: paths, name: name)
            }
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "从收藏中移除", key: "") { [weak self] in
            Preferences.savedSearches.removeAll { $0 == text }
            Preferences.savedSearchNames[text] = nil
            self?.runSearch()
        })
        let rect = table.rect(ofRow: max(0, table.selectedRow))
        menu.popUp(positioning: nil, at: point ?? NSPoint(x: rect.maxX - 180, y: rect.maxY), in: table)
    }

    /// Asks for a name for a saved search, such as "《论语》导读"; empty removes the name.
    private func askName(for text: String) {
        let alert = NSAlert()
        alert.messageText = "给这个搜索起个名字"
        alert.informativeText = "例如课程名“《论语》导读”。清空搜索框时按名字列出，↩ 即列出这门课的全部材料。\n搜索：\(text)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = Preferences.savedSearchNames[text] ?? ""
        field.placeholderString = "名称（可留空）"
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Preferences.savedSearchNames[text] = name.isEmpty ? nil : name
            self?.runSearch()
        }
    }

    private func saveCurrentSearch() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "?", text != "？" else {
            statusLabel.stringValue = "先输入要收藏的搜索，再按 ⌘S"
            return
        }
        var saved = Preferences.savedSearches
        saved.removeAll { $0 == text }
        saved.insert(text, at: 0)
        Preferences.savedSearches = saved
        statusLabel.stringValue = "已收藏“\(text)”：清空搜索框时显示在最上面"
        askName(for: text)
    }

    // MARK: - Folders

    private func enterFolder(_ item: ResultItem) {
        let origin = scrollView.contentView.bounds.origin
        browseStack.append(BrowseLevel(folder: browsedFolder, text: field.stringValue, outcome: outcome, selection: table.selectedRow, scroll: origin))
        browsedFolder = item.path
        field.stringValue = ""
        updateBackButton()
        runSearch()
    }

    @objc private func goBack() {
        guard let level = browseStack.popLast() else { return }
        restore(level)
    }

    /// ⎋ while browsing: straight back to the original search results.
    private func leaveBrowsing() {
        guard let first = browseStack.first else { return }
        browseStack.removeAll()
        restore(first)
    }

    private func resetBrowsing() {
        guard let first = browseStack.first else { return }
        browseStack.removeAll()
        browsedFolder = first.folder
        field.stringValue = first.text
        updateBackButton()
    }

    private func restore(_ level: BrowseLevel) {
        browsedFolder = level.folder
        field.stringValue = level.text
        field.currentEditor()?.moveToEndOfDocument(nil)
        updateBackButton()
        outcome = level.outcome
        results = level.outcome.items
        table.reloadData()
        if level.selection >= 0 && level.selection < results.count {
            table.selectRowIndexes(IndexSet(integer: level.selection), byExtendingSelection: false)
        }
        scrollView.contentView.scroll(to: level.scroll)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updatePreview()
        updateEmptyLabel()
        updateStatus()
    }

    private func updateBackButton() {
        let browsing = browsedFolder != nil
        let symbol = browsing ? "chevron.backward" : "magnifyingglass"
        backButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: browsing ? "返回" : "搜索")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        backButton.isEnabled = browsing
        backButton.toolTip = browsing ? "返回（← 或 ⌘↑）" : nil
        if let folder = browsedFolder {
            field.placeholderString = "在“\((folder as NSString).lastPathComponent)”中筛选…"
        } else {
            field.placeholderString = defaultPlaceholder
        }
    }

    // MARK: - Action menu (⌘K)

    /// The page or slide of the hit in `item`, when one was found.
    private func hitPage(for item: ResultItem) -> Int? {
        guard let hit = lastHit, hit.path == item.path else { return nil }
        return hit.page
    }

    /// ⌥↩: a PDF opens in the reader at the hit's page (with its table of contents);
    /// a presentation opens in PowerPoint at the slide; anything else opens as usual.
    private func openAtHit(_ item: ResultItem) {
        let ext = (item.path as NSString).pathExtension.lowercased()
        let page = hitPage(for: item)
        rememberSearch()
        if ext == "pdf" {
            hide()
            PDFOpener.open(URL(fileURLWithPath: item.path), page: page, words: outcome.highlightWords)
        } else if ext == "pptx", let page {
            hide()
            PowerPoint.open(item.path, slide: page) { message in
                guard let message else { return }
                let alert = NSAlert()
                alert.messageText = "未能直接翻到第 \(page) 张"
                alert.informativeText = message
                alert.runModal()
            }
        } else {
            hide()
            actions.open(item)
        }
    }

    /// Copies the sentence around the hit with where it comes from: a GB/T 7714
    /// reference with the page for ebooks, otherwise the file name and page (0.18).
    /// `toKongReview`: instead of copying, opens KongReview's capture window with the
    /// sentence, the book's title and author, the page, and the reference as a note (0.22).
    private func copyQuotation(_ item: ResultItem, toKongReview: Bool = false) {
        let needles = outcome.highlightWords
        let page = hitPage(for: item)
        let store = ocr.store
        statusLabel.stringValue = "正在提取引文…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let url = URL(fileURLWithPath: item.path)
            let ext = url.pathExtension.lowercased()
            var source = ""
            if let pages = try? DocumentText.read(url, firstPage: page ?? 1, maximumPages: page == nil ? 3_000 : 1, ocr: store) {
                source = pages.pages.joined(separator: "\n")
            }
            let sentence = Quotation.sentence(in: source, needles: needles)
            let stem = EbookName.splitMark(url.deletingPathExtension().lastPathComponent).stem
            let origin: String
            var book: EbookName?
            if DuplicateFinder.bookExtensions.contains(ext) {
                let info = BookInfo.read(url)
                book = info.name
                origin = Citation.make(Preferences.citationStyle, name: info.name, fallbackTitle: info.name.title, page: page).text
            } else {
                origin = "《\(stem)》" + (page.map { ext == "pptx" ? "第 \($0) 张幻灯片" : "第 \($0) 页" } ?? "")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let sentence else {
                    self.statusLabel.stringValue = "未能提取命中的句子"
                    return
                }
                if toKongReview {
                    let place = page.map { ext == "pptx" ? "第 \($0) 张幻灯片" : "第 \($0) 页" }
                    KongReviewLink.send(text: sentence, title: book?.title ?? stem, author: book?.authors, location: place, note: origin)
                    self.hide()
                    return
                }
                let text = "“\(sentence)”\n\(origin)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.statusLabel.stringValue = "已拷贝引文：“\(sentence.prefix(30))…” — \(origin)"
            }
        }
    }

    /// Copies a GB/T 7714 reference for an ebook, from its file name and (EPUB) its
    /// own metadata, and says what is missing (0.17).
    static func copyReference(for path: String) -> String {
        // The name, completed from the book's own metadata (local files only, 0.19).
        let info = BookInfo.read(URL(fileURLWithPath: path))
        let result = Citation.make(Preferences.citationStyle, name: info.name, fallbackTitle: info.name.title)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.text, forType: .string)
        var message = "已拷贝参考文献：" + result.text
        if let source = info.titleSource { message += "（书名取自\(source)）" }
        if !result.missing.isEmpty { message += "（缺" + result.missing.joined(separator: "、") + "，请补全）" }
        if !result.notes.isEmpty { message += "（" + result.notes.joined(separator: "；") + "）" }
        return message
    }

    /// ⌘K, a right-click on a result, or the 更多操作 button below the list.
    private func showActionMenu(at point: NSPoint? = nil) {
        guard let item = selectedItem, item.isFile, table.selectedRow >= 0 else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], _ handler: @escaping () -> Void) {
            let entry = ClosureMenuItem(title: title, key: key, handler: handler)
            entry.keyEquivalentModifierMask = modifiers
            menu.addItem(entry)
        }
        if item.isInArchive {
            add("打开", "o") { [weak self] in self?.openFromArchive(item) }
            add("在访达中显示压缩包", "\r") { [weak self] in self?.hide(); self?.actions.reveal(self?.archiveOrSelf(item) ?? item) }
            add("快速查看", "y") { [weak self] in self?.toggleQuickLook() }
            menu.addItem(.separator())
            add("拷贝文件（从压缩包中取出）", "c") { [weak self] in self?.copyFromArchive(item, as: .file) }
            add("拷贝压缩包内路径", "c", [.command, .option]) { [weak self] in self?.copyFromArchive(item, as: .path) }
            add("拷贝名称", "c", [.command, .shift]) { [weak self] in self?.copyFromArchive(item, as: .name) }
            let rect = table.rect(ofRow: table.selectedRow)
            menu.popUp(positioning: nil, at: point ?? NSPoint(x: rect.maxX - 180, y: rect.maxY), in: table)
            return
        }
        if item.isFolder {
            let rightArrow = String(utf16CodeUnits: [unichar(NSRightArrowFunctionKey)], count: 1)
            add("进入文件夹", rightArrow, []) { [weak self] in self?.enterFolder(item) }
        }
        add(item.isFolder ? "在访达中打开" : "打开", "o") { [weak self] in self?.hide(); self?.actions.open(item) }
        let apps = actions.applications(for: item)
        if !apps.isEmpty && !item.isFolder {
            let submenu = NSMenu()
            for app in apps {
                let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                let entry = ClosureMenuItem(title: name, key: "") { [weak self] in self?.hide(); self?.actions.open(item, with: app) }
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
                submenu.addItem(entry)
            }
            let openWith = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
            openWith.submenu = submenu
            menu.addItem(openWith)
        }
        add("在访达中显示", "\r") { [weak self] in self?.hide(); self?.actions.reveal(item) }
        add("快速查看", "y") { [weak self] in self?.toggleQuickLook() }
        let ext = (item.path as NSString).pathExtension.lowercased()
        let hitPage = self.hitPage(for: item)
        if !item.isFolder && ext == "pdf" {
            let reader = KongFolio.isReader ? "在 KongFolio 中" : "在阅读窗口中"
            add(hitPage.map { "\(reader)打开到第 \($0) 页" } ?? (KongFolio.isReader ? "在 KongFolio 中打开（接着上次读）" : "在阅读窗口中打开（含目录）"), "\r", [.option]) { [weak self] in self?.openAtHit(item) }
        } else if !item.isFolder && ext == "pptx", let hitPage {
            add("在 PowerPoint 中打开到第 \(hitPage) 张", "\r", [.option]) { [weak self] in self?.openAtHit(item) }
        }
        menu.addItem(.separator())
        if lastHit?.path == item.path {
            add(hitPage.map { "拷贝引文（含出处，第 \($0) \(ext == "pptx" ? "张" : "页")）" } ?? "拷贝引文（含出处）") { [weak self] in self?.copyQuotation(item) }
            if KongReviewLink.isInstalled {
                add("引文送到 KongReview 摘录（带书名、作者、页码）") { [weak self] in self?.copyQuotation(item, toKongReview: true) }
            }
        }
        add("拷贝文件", "c") { [weak self] in self?.statusLabel.stringValue = self?.actions.copy(item, as: .file) ?? "" }
        add("拷贝路径", "c", [.command, .option]) { [weak self] in self?.statusLabel.stringValue = self?.actions.copy(item, as: .path) ?? "" }
        add("拷贝名称", "c", [.command, .shift]) { [weak self] in self?.statusLabel.stringValue = self?.actions.copy(item, as: .name) ?? "" }
        menu.addItem(.separator())
        if !item.isFolder && !item.isInArchive {
            // Reading state as a Finder tag, one at a time (待读 / 在读 / 精读 / 已读).
            let state = FinderTags.readingState(of: item.path)
            let states = NSMenu()
            for name in FinderTags.readingStates {
                let entry = ClosureMenuItem(title: name, key: "") { [weak self] in
                    let done = FinderTags.setReadingState(name, on: item.path)
                    self?.statusLabel.stringValue = done ? "已标为“\(name)”：\(item.name)（搜索 标签:\(name) 可找出全部）" : "无法更改标签"
                }
                entry.state = name == state ? .on : .off
                states.addItem(entry)
            }
            if state != nil {
                states.addItem(.separator())
                states.addItem(ClosureMenuItem(title: "清除阅读状态", key: "") { [weak self] in
                    let done = FinderTags.setReadingState(nil, on: item.path)
                    self?.statusLabel.stringValue = done ? "已清除阅读状态：\(item.name)" : "无法更改标签"
                })
            }
            let stateItem = NSMenuItem(title: "阅读状态" + (state.map { "：\($0)" } ?? "（访达标签）"), action: nil, keyEquivalent: "")
            stateItem.submenu = states
            menu.addItem(stateItem)
        }
        if DuplicateFinder.bookExtensions.contains((item.path as NSString).pathExtension.lowercased()) {
            add("拷贝为参考文献（GB/T 7714）") { [weak self] in
                self?.statusLabel.stringValue = SearchWindowController.copyReference(for: item.path)
            }
        }
        if !item.isFolder && ["pptx", "pdf", "docx"].contains(ext) {
            add("与另一版本比较…") { [weak self] in
                self?.hide()
                CompareWindowController.shared.present(old: nil, new: URL(fileURLWithPath: item.path))
            }
        }
        if !item.isFolder && ext == "pdf" {
            add("生成可搜索的 PDF（另存一份）") { [weak self] in
                self?.hide()
                SearchablePDFWindowController.shared.start(URL(fileURLWithPath: item.path))
            }
        }
        add("把全部结果放入文件清单（书单、参考文献、批量操作）") { [weak self] in
            guard let self else { return }
            let paths = self.results.filter { $0.isFile && !$0.isFolder && !$0.isInArchive }.map(\.path)
            let title = self.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.hide()
            self.onFileList?(.paths(paths, title: title))
        }
        add("批量重命名…") { [weak self] in
            self?.hide()
            self?.onBatchRename?([URL(fileURLWithPath: item.path)])
        }
        add("在“终端”中打开") { [weak self] in
            if let message = self?.actions.openInTerminal(item) { self?.statusLabel.stringValue = message } else { self?.hide() }
        }
        if outcome.isRecentList {
            add("从“最近打开”中移除", "\u{8}") { [weak self] in Preferences.forget(item.path); self?.runSearch() }
        }
        menu.addItem(.separator())
        add("移到废纸篓", "\u{8}") { [weak self] in self?.trash(item) }

        let rect = table.rect(ofRow: table.selectedRow)
        menu.popUp(positioning: nil, at: point ?? NSPoint(x: rect.maxX - 180, y: rect.maxY), in: table)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = results[row]
        if item.isHeader {
            let headerID = NSUserInterfaceItemIdentifier("FolderHeader")
            let label = (tableView.makeView(withIdentifier: headerID, owner: nil) as? NSTextField) ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = headerID
                field.font = .systemFont(ofSize: 11, weight: .semibold)
                field.textColor = .secondaryLabelColor
                field.lineBreakMode = .byTruncatingHead
                return field
            }()
            label.stringValue = "  📁 " + item.name + "（\(item.score) 个）"
            label.toolTip = String(item.path.dropFirst("header:".count))
            return label
        }
        let identifier = NSUserInterfaceItemIdentifier("ResultCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? ResultCellView) ?? ResultCellView(identifier: identifier)
        let location: String
        let image: NSImage
        if let fill = item.fill {
            location = fill.isSaved
                ? (item.name == fill.text ? "" : fill.text + " · ") + "收藏的搜索 · ↩ 搜索 · ⌘K 命名"
                : (fill.isHistory ? "搜索历史 · ↩ 再次搜索 · ⌘⌫ 删除" : fill.explanation)
            let symbol = fill.isSaved ? "star" : (fill.isHistory ? "clock.arrow.circlepath" : "text.magnifyingglass")
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: fill.explanation) ?? NSImage()
        } else if let link = item.link {
            location = link.host ?? link.scheme ?? ""
            image = NSImage(systemSymbolName: "globe", accessibilityDescription: "网页搜索") ?? NSImage()
        } else if item.definition != nil {
            location = "系统词典 · ↩ 在“词典”中打开 · ⌘C 拷贝释义"
            image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "词典") ?? NSImage()
        } else if let inner = item.innerPath {
            let folder = (inner as NSString).deletingLastPathComponent
            location = Self.displayLocation(of: item.path) + " › 压缩包 " + (item.path as NSString).lastPathComponent + (folder.isEmpty ? "" : " › " + folder)
            image = icon(forExtension: (item.name as NSString).pathExtension)
        } else {
            location = Self.displayLocation(of: item.path) + (item.recognized ? " · 识别文字" : "")
            image = icon(for: item.path)
        }
        cell.configure(
            name: item.isFile ? highlighted(item.name) : NSAttributedString(string: item.name, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.labelColor]),
            location: location,
            icon: image,
            shortcut: { let n = (selectableRows.firstIndex(of: row) ?? 99) + 1; return n <= 9 ? "⌘\(n)" : "" }()
        )
        return cell
    }

    /// Dragging a result out (to WeChat, Mail, Finder…) copies the file. A file in
    /// an archive can be dragged once its preview copy has been taken out.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard results.indices.contains(row) else { return nil }
        let item = results[row]
        if let link = item.link { return link as NSURL }
        guard item.isFile, item.definition == nil else { return nil }
        if item.isInArchive { return archivePreviews[Self.archiveKey(item)].map { $0 as NSURL } }
        return URL(fileURLWithPath: item.path) as NSURL
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        results.indices.contains(row) && !results[row].isHeader
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        results.indices.contains(row) && results[row].isHeader
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        results.indices.contains(row) && results[row].isHeader ? 22 : tableView.rowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    private func updatePreview() {
        let selected = selectedItem
        if hitPreview.document?.documentURL?.path != selected?.path { hideHitPreview() }
        definitionScroll.isHidden = selected?.isFile ?? true
        if let item = selected, let fill = item.fill {
            definitionView.string = fill.isSaved || fill.isHistory
                ? "↩ 搜索：\(fill.text)\n\n⌘⌫ " + (fill.isSaved ? "从收藏中移除。在任意搜索时按 ⌘S 可收藏当前搜索。" : "从搜索历史中删除。在 设置 › 通用 可关闭或清除搜索历史。")
                : "\(fill.text)\n\n\(fill.explanation)\n\n↩ 或单击：加入搜索框" + (fill.select.map { "，并选中“\($0)”方便直接改写" } ?? "") + "。"
            definitionView.scrollToBeginningOfDocument(nil)
        } else if let item = selected, !item.isFile {
            definitionView.string = item.definition.map { $0.isEmpty ? "系统词典中没有“\(item.name)”。\n可在“词典”App 的设置中启用更多词典（如现代汉语词典、牛津英汉汉英词典），或用汉典查询。" : $0 }
                ?? "↩ 在浏览器中打开：\n\(item.link?.absoluteString ?? "")"
            definitionView.scrollToBeginningOfDocument(nil)
        }
        let url = selected.flatMap(previewURL(for:))
        if let item = selected, item.isInArchive { loadArchivePreview(item) }
        if (preview.previewItem as? NSURL).map({ $0 as URL }) != url {
            preview.previewItem = url as NSURL?
        }
        updateSnippet()
    }

    /// In full-text mode, the passage around the first match, with its PDF page.
    private func updateSnippet() {
        snippetToken += 1
        let token = snippetToken
        lastHit = nil
        if !contentMode {
            updateNameModeSnippet(token: token)
            return
        }
        guard outcome.isContent, let item = selectedItem, !item.isFolder else {
            snippetLabel.stringValue = ""
            return
        }
        let needles = outcome.highlightWords
        let store = ocr.store
        snippetLabel.attributedStringValue = NSAttributedString(string: "正在查找命中位置…", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = ContentPreview.find(in: URL(fileURLWithPath: item.path), needles: needles, ocr: store)
            DispatchQueue.main.async {
                guard let self, token == self.snippetToken else { return }
                if case .found(let place) = found {
                    self.lastHit = (item.path, place.page)
                    self.showHitPage(item.path, page: place.page, words: needles)
                } else {
                    self.hideHitPreview()
                }
                self.snippetLabel.attributedStringValue = Self.snippetText(found)
            }
        }
    }

    /// In name mode, when the words also occur in the selected document's text, the
    /// passage (and page) is shown above the preview; otherwise the area stays closed.
    /// Looked up after a short pause, one at a time, so moving through the list stays quick.
    private func updateNameModeSnippet(token: Int) {
        setNameSnippetVisible(false)
        if lastHitPreviewQuery != outcome.highlightWords { hideHitPreview() }
        lastHitPreviewQuery = outcome.highlightWords
        guard !outcome.isRecentList, !outcome.highlightWords.isEmpty, let item = selectedItem, item.isFile,
              !item.isFolder, !item.isInArchive, ContentPreview.canRead(item.path) else { return }
        let needles = outcome.highlightWords
        let store = ocr.store
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, token == self.snippetToken else { return }
            self.snippetQueue.async {
                let found = ContentPreview.find(in: URL(fileURLWithPath: item.path), needles: needles, ocr: store)
                DispatchQueue.main.async {
                    guard token == self.snippetToken, !self.contentMode, case .found(let place) = found else { return }
                    self.lastHit = (item.path, place.page)
                    self.showHitPage(item.path, page: place.page, words: needles)
                    let text = NSMutableAttributedString(string: "正文也有  ", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
                    text.append(Self.snippetText(found))
                    self.snippetLabel.attributedStringValue = text
                    self.setNameSnippetVisible(true)
                }
            }
        }
    }

    /// Shows the hit page of a PDF in the preview area, words in yellow (0.23).
    private func showHitPage(_ path: String, page: Int?, words: [String]) {
        guard let page, page >= 1, path.lowercased().hasSuffix(".pdf"), selectedItem?.isInArchive != true else { return }
        hitPreviewToken += 1
        let token = hitPreviewToken
        let url = URL(fileURLWithPath: path)
        let reuse = hitPreview.document?.documentURL?.path == path ? hitPreview.document : nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let document = reuse ?? PDFDocument(url: url)
            DispatchQueue.main.async {
                guard let self, token == self.hitPreviewToken, self.selectedItem?.path == path,
                      let document, !document.isLocked, page <= document.pageCount, let target = document.page(at: page - 1) else { return }
                if self.hitPreview.document !== document { self.hitPreview.document = document }
                var marks: [PDFSelection] = []
                if let text = target.string {
                    marks = TextLocator.ranges(of: words, in: text).compactMap { target.selection(for: $0) }
                }
                for mark in marks { mark.color = .systemYellow }
                self.hitPreview.highlightedSelections = marks.isEmpty ? nil : marks
                self.hitPreview.isHidden = false
                if let first = marks.first { self.hitPreview.go(to: first) } else { self.hitPreview.go(to: target) }
            }
        }
    }

    private func hideHitPreview() {
        hitPreviewToken += 1
        guard !hitPreview.isHidden || hitPreview.document != nil else { return }
        hitPreview.isHidden = true
        hitPreview.highlightedSelections = nil
        hitPreview.document = nil
    }

    private func setNameSnippetVisible(_ visible: Bool) {
        guard !contentMode else { return }
        if !visible { snippetLabel.stringValue = "" }
        let height: CGFloat = visible ? 72 : 0
        if snippetHeight.constant != height { snippetHeight.constant = height }
    }

    private static func snippetText(_ outcome: ContentPreview.Outcome) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let note: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        switch outcome {
        case .found(let found):
            let result = NSMutableAttributedString()
            if let page = found.page {
                result.append(NSAttributedString(string: "第 \(page) 页", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.controlAccentColor]))
                result.append(NSAttributedString(string: "（⌥↩ 打开到此处，⌘K 拷贝引文）  ", attributes: note))
            }
            if found.recognized {
                result.append(NSAttributedString(string: "识别文字  ", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.systemOrange]))
            }
            let start = result.length
            result.append(NSAttributedString(string: found.snippet.text, attributes: base))
            let range = NSRange(location: start + found.snippet.highlight.location, length: found.snippet.highlight.length)
            result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4), range: range)
            return result
        case .notFound:
            return NSAttributedString(string: "Spotlight 认为此文件匹配，但未能定位原文（可能命中的是元数据，或词语被分隔）。", attributes: note)
        case .notDownloaded:
            return NSAttributedString(string: "此文件在 iCloud 中尚未下载到本机，不读取正文。", attributes: note)
        case .unsupported:
            return NSAttributedString(string: "此类文件不显示命中原文（支持 PDF、Word、RTF 与纯文本）。", attributes: note)
        }
    }

    /// A generic icon for a file type, for files inside archives.
    private func icon(forExtension ext: String) -> NSImage {
        let key = "\u{0}ext:" + ext.lowercased()
        if let cached = icons.object(forKey: key as NSString) { return cached }
        let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        image.size = NSSize(width: 32, height: 32)
        icons.setObject(image, forKey: key as NSString)
        return image
    }

    private func icon(for path: String) -> NSImage {
        if let cached = icons.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        icons.setObject(image, forKey: path as NSString)
        return image
    }

    /// The name with the parts that matched marked: typed text, pinyin
    /// (full spelling or initials) or an abbreviation.
    private func highlighted(_ name: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        for range in MatchHighlighter.ranges(in: name, words: outcome.highlightWords) {
            result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: range)
        }
        return result
    }

    /// Parent folder with ~ for the home folder and a readable name for iCloud Drive.
    static func displayLocation(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let cloud = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
        if parent == cloud { return "iCloud 云盘" }
        if parent.hasPrefix(cloud + "/") { return "iCloud 云盘/" + String(parent.dropFirst(cloud.count + 1)) }
        return (parent as NSString).abbreviatingWithTildeInPath
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func run() {
        handler()
    }
}

/// One row: icon, name, folder, and the ⌘-number shortcut.
final class ResultCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let locationLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        nameLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.font = .systemFont(ofSize: 11)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.lineBreakMode = .byTruncatingHead
        shortcutLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        shortcutLabel.textColor = .tertiaryLabelColor
        for view in [iconView, nameLabel, locationLabel, shortcutLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),
            locationLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            locationLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            locationLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(name: NSAttributedString, location: String, icon: NSImage, shortcut: String) {
        nameLabel.attributedStringValue = name
        locationLabel.stringValue = location
        iconView.image = icon
        shortcutLabel.stringValue = shortcut
    }
}

/// The result list; a right-click selects the row and asks for its menu (0.22).
final class ResultTable: NSTableView {
    var onContextMenu: ((Int, NSPoint) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 { onContextMenu?(row, point) }
        return nil
    }
}
