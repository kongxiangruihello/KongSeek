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
final class SearchWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let panel: SearchPanel
    private let service: IndexService
    private let ocr: OCRService
    private let field = NSTextField()
    /// 筛选按钮 (0.36): pieces of syntax added to the search with a click.
    private let filterBar = NSStackView()
    /// 条件标签 (0.42): the conditions of the search, each with × to take it out.
    private let conditionBar = NSStackView()
    private var conditionHeight: NSLayoutConstraint!
    private var chips: [QueryChips.Chip] = []
    /// 在预览中查找 (0.43): ⌘F looks for other words inside the selected file.
    private let previewFind = NSSearchField()
    private var previewFindWords: [String]?
    private var previewFindPath: String?
    /// 排序 (0.38): 相关度, 修改时间, 大小, 名称.
    private let orderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var filterBarHeight: NSLayoutConstraint!
    private var filterFragments: [FilterFragments.Fragment] = []
    private var filterLines: [String] = []
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
    /// Every hit in the selected file (0.36, after Recoll's snippets window), and which is shown.
    private var hitList: (path: String, places: [HitPlace])?
    private var hitPosition = 0
    /// 邻近搜索 (0.36): which full-text results have the words close together.
    private var proximityChecked: [String: Bool] = [:]
    private var proximityStarted = false
    /// 按命中次数 (0.41): how often the words occur in each full-text result.
    private var hitCounts: [String: Int] = [:]
    private var hitCountStarted = false
    /// Showing 相关文件 of one result (0.39); ⎋ goes back to the search.
    private var showingRelated = false
    /// A completion on offer (0.41): what was typed, and the field as shown.
    private var completion: (typed: String, full: String)?
    private var lastTypedLength = 0
    private var ebookPreviewToken = 0

    struct HitPlace {
        var page: Int?
        var snippet: Snippet
    }
    private var pendingContentSearch: DispatchWorkItem?
    /// The full-text search in progress: Spotlight results and recognized-text
    /// (OCR) results arrive separately and are merged.
    private var contentToken = 0
    private var spotlightItems: [ResultItem] = []
    private var spotlightFinished = false
    private var ocrItems: [ResultItem] = []
    private var contentQuery = SearchQuery("")
    /// Other names of the words searched in full text (0.35), highlighted too.
    private var contentAliasWords: [String] = []
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
    /// 出处汇编 of the words searched (0.27).
    var onConcordance: ((String) -> Void)?
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
    private static let height: CGFloat = 524

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
        rebuildFilterBar()
        lastTypedLength = 0
        completion = nil
        Preferences.nextTip += 1
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

        filterBar.orientation = .horizontal
        filterBar.spacing = 4
        filterBar.alignment = .centerY
        filterBar.detachesHiddenViews = true
        orderPopup.controlSize = .small
        orderPopup.font = .systemFont(ofSize: 11)
        for order in ResultOrder.allCases { orderPopup.addItem(withTitle: "按" + order.title) }
        orderPopup.selectItem(at: ResultOrder.allCases.firstIndex(of: Preferences.resultOrder) ?? 0)
        orderPopup.target = self
        orderPopup.action = #selector(orderChanged)
        orderPopup.toolTip = "结果按相关度、修改时间、大小或名称排序（全文搜索同样适用）"
        conditionBar.orientation = .horizontal
        conditionBar.spacing = 4
        conditionBar.alignment = .centerY
        previewFind.placeholderString = "在这个文件中查找（↩ 查找，⎋ 关闭）"
        previewFind.controlSize = .small
        previewFind.font = .systemFont(ofSize: 12)
        previewFind.sendsWholeSearchString = true
        previewFind.target = self
        previewFind.action = #selector(previewFindSubmitted)
        previewFind.delegate = self
        previewFind.isHidden = true
        for view in [conditionBar, orderPopup, filterBar, searchIcon, field, helpButton, modeButton, topLine, scroll, middleLine, snippetLabel, preview, hitPreview, definitionScroll, emptyLabel, bottomLine, statusLabel, hints, previewFind] as [NSView] { // previewFind last: above the preview
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

            filterBar.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            filterBar.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: -2),
            filterBar.trailingAnchor.constraint(lessThanOrEqualTo: orderPopup.leadingAnchor, constant: -8),
            orderPopup.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            orderPopup.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor),
            conditionBar.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 4),
            conditionBar.leadingAnchor.constraint(equalTo: filterBar.leadingAnchor),
            conditionBar.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -16),
            topLine.topAnchor.constraint(equalTo: conditionBar.bottomAnchor, constant: 6),
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
            previewFind.topAnchor.constraint(equalTo: preview.topAnchor, constant: 6),
            previewFind.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -8),
            previewFind.widthAnchor.constraint(equalToConstant: 240),

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
        filterBarHeight = filterBar.heightAnchor.constraint(equalToConstant: 0)
        filterBarHeight.isActive = true
        conditionHeight = conditionBar.heightAnchor.constraint(equalToConstant: 0)
        conditionHeight.isActive = true

        rebuildFilterBar()
        updateEmptyLabel()
    }

    // MARK: - Filter buttons (0.36)

    /// The buttons from the settings; rebuilt when they change.
    private func rebuildFilterBar() {
        let lines = Preferences.showFilterButtons ? Preferences.filterButtonLines : []
        guard lines != filterLines || filterBar.arrangedSubviews.isEmpty != lines.isEmpty else { return }
        filterLines = lines
        filterFragments = FilterFragments(lines: lines).fragments
        for view in filterBar.arrangedSubviews { filterBar.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, fragment) in filterFragments.enumerated() {
            let button = NSButton(title: fragment.title, target: self, action: #selector(filterButtonClicked(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.tag = index
            button.toolTip = "加入或去掉 " + fragment.text + "（设置 › 搜索 › 筛选按钮… 可改）"
            filterBar.addArrangedSubview(button)
        }
        filterBarHeight.constant = 22
        refreshFilterButtons()
    }

    /// One label per condition of the search (0.42), besides those the filter buttons show,
    /// and the order when it is not 相关度; × takes it out.
    private func refreshConditionChips() {
        let text = queryText
        let shownByButtons = Set(filterFragments.filter { FilterFragments.isActive($0, in: text) }
            .flatMap { $0.text.split(separator: " ").map { $0.lowercased() } })
        var current = QueryChips.chips(for: text).filter { !shownByButtons.contains($0.token.lowercased()) }
        if Preferences.resultOrder != .relevance {
            current.append(QueryChips.Chip(title: "按" + Preferences.resultOrder.title + "排序", token: ""))
        }
        guard current != chips || conditionBar.arrangedSubviews.count != current.count else { return }
        chips = current
        for view in conditionBar.arrangedSubviews { conditionBar.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, chip) in current.enumerated() {
            let button = NSButton(title: chip.title + "  ×", target: self, action: #selector(removeChip(_:)))
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.tag = index
            button.toolTip = chip.token.isEmpty ? "改回按相关度排序" : "去掉条件 " + chip.token
            conditionBar.addArrangedSubview(button)
        }
        conditionHeight.constant = current.isEmpty ? 0 : 20
    }

    @objc private func removeChip(_ sender: NSButton) {
        guard chips.indices.contains(sender.tag) else { return }
        let chip = chips[sender.tag]
        if chip.token.isEmpty {
            Preferences.resultOrder = .relevance
            orderPopup.selectItem(at: 0)
        } else {
            let updated = QueryChips.removing(chip, from: queryText)
            field.stringValue = updated.isEmpty ? "" : updated + " "
            completion = nil
        }
        panel.makeFirstResponder(field)
        field.currentEditor()?.moveToEndOfDocument(nil)
        runSearch()
    }

    @objc private func orderChanged() {
        let all = ResultOrder.allCases
        Preferences.resultOrder = all[max(0, min(orderPopup.indexOfSelectedItem, all.count - 1))]
        panel.makeFirstResponder(field)
        field.currentEditor()?.moveToEndOfDocument(nil)
        runSearch()
    }

    /// Each button pressed while its piece of syntax is in the search.
    private func refreshFilterButtons() {
        let text = field.stringValue
        for case let button as NSButton in filterBar.arrangedSubviews where filterFragments.indices.contains(button.tag) {
            button.state = FilterFragments.isActive(filterFragments[button.tag], in: text) ? .on : .off
        }
    }

    @objc private func filterButtonClicked(_ sender: NSButton) {
        guard filterFragments.indices.contains(sender.tag) else { return }
        let updated = FilterFragments.toggled(filterFragments[sender.tag], in: field.stringValue)
        field.stringValue = updated.isEmpty ? "" : updated + " "
        panel.makeFirstResponder(field)
        field.currentEditor()?.moveToEndOfDocument(nil)
        refreshFilterButtons()
        runSearch()
    }

    // MARK: - Searching

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === field else { return }
        // Wait while a Chinese input method is still composing.
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        applyCompletion()
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

    // MARK: - Completion (0.41)

    /// What is typed, without a completion still on offer.
    private var queryText: String {
        if let completion, field.stringValue == completion.full { return completion.typed }
        return field.stringValue
    }

    /// Offers the rest of a search used before, a saved search or a file opened lately,
    /// selected, so typing on replaces it and → takes it. Only while typing forward.
    private func applyCompletion() {
        let value = field.stringValue
        let length = (value as NSString).length
        let grew = length > lastTypedLength
        lastTypedLength = length
        completion = nil
        guard Preferences.autocomplete, grew, browsedFolder == nil, let editor = field.currentEditor() else { return }
        let selection = editor.selectedRange
        guard selection.length == 0, selection.location == length else { return }
        guard let full = Autocomplete.completion(for: value, candidates: completionCandidates()) else { return }
        field.stringValue = full
        editor.selectedRange = NSRange(location: length, length: (full as NSString).length - length)
        completion = (value, full)
    }

    private func completionCandidates() -> [String] {
        let opened = Preferences.lastOpened.sorted { $0.value > $1.value }.prefix(300).map { (($0.key as NSString).lastPathComponent as NSString).deletingPathExtension }
        return Preferences.searchHistory + Preferences.savedSearches + opened
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
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = SearchQuery(text)
        let aliases = Preferences.searchAliases
        guard let queryString = SpotlightQuery.content(for: query, aliases: aliases) else {
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
        proximityChecked = [:]
        proximityStarted = false
        hitCounts = [:]
        hitCountStarted = false

        // Recognized text of scans, searched in memory off the main thread.
        let store = ocr.store
        // The words as typed, then with other names of a person or book (0.35).
        let needleSets = [query.highlightWords] + aliases.expansions(of: query.words).map { $0 + query.phrases }
        contentAliasWords = Array(Set(needleSets.flatMap { $0 }).subtracting(query.highlightWords))
        // KongSeek's own text index (0.37): each word by any of its other names too.
        let bookWords = query.words.map { [$0] + aliases.alternatives(for: $0) } + query.phrases.map { [$0] }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var seenPaths = Set<String>()
            var hits: [OCRHit] = []
            for needles in needleSets {
                for hit in store.search(needles, limit: 300, accept: { path in !rules.excludes(path: path, roots: ocrRoots) })
                where seenPaths.insert(hit.path).inserted {
                    hits.append(hit)
                }
            }
            func item(_ path: String) -> ResultItem? {
                let name = (path as NSString).lastPathComponent
                let folded = SearchText.fold(name)
                guard !excluded.contains(where: { folded.contains($0) }), SearchWindowController.accepts(name: folded, query: query),
                      query.acceptsExternal(path: path, isFolder: false) else { return nil }
                if query.needsMetadata && !query.acceptsMetadata(EntryMetadata.read(path: path)) { return nil }
                return ResultItem(path: path, name: name, isFolder: false, score: 0)
            }
            var items = hits.compactMap { hit -> ResultItem? in
                guard var found = item(hit.path) else { return nil }
                found.recognized = true
                return found
            }
            for hit in BookTextService.shared.search(bookWords, limit: 300, accept: { !rules.excludes(path: $0, roots: roots) })
            where seenPaths.insert(hit.path).inserted {
                if var found = item(hit.path) {
                    found.ownText = true
                    items.append(found)
                }
            }
            DispatchQueue.main.async {
                guard let self, token == self.contentToken else { return }
                self.ocrItems = items
                self.publishContent()
            }
        }

        let spotlightStart = CFAbsoluteTimeGetCurrent()
        let started = contentSearch.search(queryString, scopes: roots) { [weak self] hits, finished in
            guard let self, token == self.contentToken else { return }
            if finished && !self.spotlightFinished { IndexService.recordTiming("全文搜索（Spotlight）", since: spotlightStart, detail: text) }
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
        var merged = ocrItems + spotlightItems.filter { seen.insert($0.path).inserted }
        var outcome = SearchOutcome(highlightWords: query.highlightWords + contentAliasWords, notes: query.descriptions + query.natural.descriptions + (note.map { [$0] } ?? []))
        if !contentAliasWords.isEmpty { outcome.notes.append("同义词：" + contentAliasWords.joined(separator: "、")) }
        outcome.isContent = true
        outcome.gathering = !spotlightFinished
        if query.advanced.needsProximity {
            // near: / 同页: (0.36): each file's text is read to see how close the words stand.
            let candidates = Array(merged.prefix(Self.proximityLimit))
            if spotlightFinished && !proximityStarted {
                proximityStarted = true
                checkProximity(candidates.map(\.path), query: query, token: contentToken)
            }
            let checked = candidates.filter { proximityChecked[$0.path] != nil }.count
            if spotlightFinished && checked < candidates.count {
                outcome.gathering = true
                outcome.notes.append("正在核对词语的距离：\(checked) / \(candidates.count)")
            } else if merged.count > Self.proximityLimit {
                outcome.notes.append("只核对了前 \(Self.proximityLimit) 个文件")
            }
            merged = candidates.filter { proximityChecked[$0.path] == true }
        }
        // 作者: / 出版社: / 年: (0.38) on full-text results: by name and confirmed records (no EPUB reading here).
        if query.advanced.book.isActive {
            let records = BookRecords.current()
            let aliases = Preferences.searchAliases
            merged = merged.filter { item in
                guard DuplicateFinder.bookExtensions.contains((item.path as NSString).pathExtension.lowercased()) else { return false }
                let stem = EbookName.splitMark(((item.name as NSString).deletingPathExtension)).stem
                var details = EbookName.parse(stem)
                if records.record(for: item.path) != nil { details = records.apply(to: details ?? EbookName(title: stem), path: item.path) }
                return query.advanced.book.accepts(details: details, fileName: item.name, aliases: aliases)
            }
        }
        // 排序 (0.38).
        let order = Preferences.resultOrder
        if order != .relevance {
            func key(_ item: ResultItem) -> (Double, Int64) {
                var info = stat()
                guard lstat(item.path, &info) == 0 else { return (0, 0) }
                return (Double(info.st_mtimespec.tv_sec), Int64(info.st_size))
            }
            let keys = Dictionary(merged.map { ($0.path, key($0)) }, uniquingKeysWith: { first, _ in first })
            switch order {
            case .modified: merged.sort { (keys[$0.path]?.0 ?? 0) > (keys[$1.path]?.0 ?? 0) }
            case .size: merged.sort { (keys[$0.path]?.1 ?? 0) > (keys[$1.path]?.1 ?? 0) }
            case .name: merged.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .relevance: break
            case .hits:
                // 按命中次数 (0.41): each file's text is read and the words counted.
                let candidates = Array(merged.prefix(Self.proximityLimit))
                if spotlightFinished && !hitCountStarted {
                    hitCountStarted = true
                    countHits(candidates.map(\.path), words: query.highlightWords + contentAliasWords, token: contentToken)
                }
                let counted = candidates.filter { hitCounts[$0.path] != nil }.count
                if spotlightFinished && counted < candidates.count {
                    outcome.gathering = true
                    outcome.notes.append("正在统计命中次数：\(counted) / \(candidates.count)")
                }
                let position = Dictionary(merged.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: { first, _ in first })
                merged.sort { a, b in
                    let x = hitCounts[a.path] ?? -1, y = hitCounts[b.path] ?? -1
                    return x != y ? x > y : (position[a.path] ?? 0) < (position[b.path] ?? 0)
                }
                for index in merged.indices { merged[index].hitCount = hitCounts[merged[index].path] }
            }
            outcome.notes.append("按\(order.title)排序")
        }
        outcome.matchCount = merged.count
        outcome.items = Array(merged.prefix(200))
        IndexService.annotate(&outcome.items, notes: Records.notes)
        show(outcome)
    }

    static let proximityLimit = 300

    /// Counts the words in each file's text (0.41), in the background, a few at a time.
    private func countHits(_ paths: [String], words: [String], token: Int) {
        let store = ocr.store
        let start = CFAbsoluteTimeGetCurrent()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { IndexService.recordTiming("命中统计", since: start, detail: "\(paths.count) 个文件") }
            var batch: [String: Int] = [:]
            func flush() {
                let done = batch
                batch = [:]
                DispatchQueue.main.async {
                    guard let self, token == self.contentToken else { return }
                    self.hitCounts.merge(done) { _, new in new }
                    self.publishContent()
                }
            }
            for (number, path) in paths.enumerated() {
                guard let current = self, token == current.contentToken else { return }
                let url = URL(fileURLWithPath: path)
                var count = 0
                if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus != .notDownloaded,
                   let pages = QuoteLookup.readCached(url, ocr: store) {
                    count = HitCount.count(words, in: pages.pages)
                }
                batch[path] = count
                if number % 5 == 4 { flush() }
            }
            flush()
        }
    }

    /// Reads each file's text (from the text cache when it is there) and keeps those
    /// where the words stand within `near:` characters, or on one page.
    private func checkProximity(_ paths: [String], query: SearchQuery, token: Int) {
        let aliases = Preferences.searchAliases
        let words = (query.words + query.phrases).map { word -> [String] in
            var forms: [String] = []
            for name in [word] + (query.words.contains(word) ? aliases.alternatives(for: word) : []) {
                for variant in SearchText.scriptVariants(name) where !forms.contains(variant) { forms.append(variant) }
            }
            return forms
        }
        let distance = query.advanced.near
        let store = ocr.store
        let start = CFAbsoluteTimeGetCurrent()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { IndexService.recordTiming("邻近核对", since: start, detail: "\(paths.count) 个文件") }
            var batch: [String: Bool] = [:]
            func flush() {
                let done = batch
                batch = [:]
                DispatchQueue.main.async {
                    guard let self, token == self.contentToken else { return }
                    self.proximityChecked.merge(done) { _, new in new }
                    self.publishContent()
                }
            }
            for (number, path) in paths.enumerated() {
                guard let current = self, token == current.contentToken else { return }
                let url = URL(fileURLWithPath: path)
                var close = false
                if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus != .notDownloaded,
                   let pages = QuoteLookup.readCached(url, ocr: store) {
                    close = Proximity.firstPage(pages.pages, words: words, distance: distance) != nil
                }
                batch[path] = close
                if number % 5 == 4 { flush() }
            }
            flush()
        }
    }

    /// The ext: and -ext: parts of a query, for results that did not come from Spotlight.
    private static func accepts(name foldedName: String, query: SearchQuery) -> Bool {
        if !query.extensions.isEmpty && !query.extensions.contains(where: { foldedName.hasSuffix("." + $0) }) { return false }
        return !query.excludedExtensions.contains { foldedName.hasSuffix("." + $0) }
    }

    func runSearch() {
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        HangMonitor.note("搜索：" + text)
        showingRelated = false
        refreshFilterButtons()
        refreshConditionChips()
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
        service.search(queryText, precision: Preferences.precision) { [weak self] outcome in
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
        if Preferences.groupByFolder && browsedFolder == nil && !newOutcome.isRecentList && !newOutcome.isRelated && !query.isEmpty {
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
        if control === previewFind {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                closePreviewFind()
                return true
            }
            return false
        }
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
            // → takes the completion shown in grey (0.41).
            if let completion, field.stringValue == completion.full {
                textView.selectedRange = NSRange(location: (textView.string as NSString).length, length: 0)
                self.completion = nil
                lastTypedLength = (textView.string as NSString).length
                runSearch()
                return true
            }
            // → at the end of the text enters the selected folder.
            let selection = textView.selectedRange()
            guard let item = selectedItem, item.isFolder, selection.length == 0, selection.location == (textView.string as NSString).length else { return false }
            enterFolder(item)
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.deleteBackward(_:)):
            guard browsedFolder != nil, fieldEmpty else { return false }
            goBack()
        case #selector(NSResponder.cancelOperation(_:)):
            if showingRelated {
                runSearch()
            } else if browsedFolder != nil {
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
        // Typing in 在预览中查找: only the hit keys (⌘] ⌘[ ⌘J ⌘F) act on the file; ⌘⌫ and
        // the rest stay with the text being typed.
        if let editor = panel.firstResponder as? NSTextView, (editor.delegate as AnyObject?) === previewFind,
           !(modifiers == [.command] && [30, 33, 38, 3].contains(keyCode)) {
            return false
        }
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
            case 30: // ⌘]: next hit in the file (0.36)
                return stepHit(1)
            case 33: // ⌘[: previous hit
                return stepHit(-1)
            case 38: // ⌘J: every hit in the file
                return showHitMenu()
            case 3: // ⌘F: find inside the selected file (0.43)
                return openPreviewFind()
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
            if fill.isPresetPicker { showPresetMenu(); return }
            apply(fill)
            return
        }
        rememberSearch()
        rememberChoice(item)
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
        // 文件夹跳转 (0.40): ↩ goes into the folder.
        if outcome.isFolderJump && item.isFolder {
            rememberChoice(item)
            enterFolder(item)
            return
        }
        hide()
        actions.open(item)
    }

    private func revealSelected() {
        guard let item = selectedItem, item.isFile else { return }
        rememberSearch()
        rememberChoice(item)
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

    /// 文件备注 (0.40): a line or two about the file, kept by KongSeek; searched with 备注:.
    private func editNote(_ item: ResultItem) {
        let alert = NSAlert()
        alert.messageText = "备注：" + item.name
        alert.informativeText = "写给自己看的一两句话，如“讲‘仁’的部分在第三章”。存在 KongSeek 里，不改动文件；搜索 备注:仁 可找出来，结果中也会显示。清空即删除。"
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 360, height: 90)
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.font = .systemFont(ofSize: 13)
        text.isRichText = false
        text.string = Records.notes.note(for: item.path)?.text ?? ""
        alert.accessoryView = scroll
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = text
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            var notes = Records.notes
            notes.set(text.string, for: item.path)
            Records.notes = notes
            self?.statusLabel.stringValue = notes.note(for: item.path) == nil ? "已删除备注：\(item.name)" : "已保存备注：\(item.name)（搜索 备注: 可列出全部有备注的文件）"
            self?.runSearch()
        }
    }

    /// 相关文件 (0.39) of a result, in place of the results until ⎋.
    private func showRelated(_ item: ResultItem) {
        statusLabel.stringValue = "正在查找“\(item.name)”的相关文件…"
        service.related(to: item.path) { [weak self] outcome in
            guard let self else { return }
            self.contentToken += 1
            self.contentSearch.stop()
            self.show(outcome)
            self.showingRelated = true
        }
    }

    /// Which file was opened after this name search (0.35), so the same query puts it first.
    private func rememberChoice(_ item: ResultItem) {
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contentMode, browsedFolder == nil, item.isFile, !item.isInArchive, !text.isEmpty, text != "?", text != "？",
              DictionaryLookup.word(in: text) == nil else { return }
        Records.recordChoice(query: text, path: item.path)
    }

    /// 添加常用收藏搜索 (0.35): the preset searches, each added to 收藏 or taken out again.
    private func showPresetMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "常用搜索：选一项加入收藏，再选一次移除", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for preset in SavedSearchPresets.all {
            let saved = Preferences.savedSearches.contains(preset.query)
            let item = ClosureMenuItem(title: preset.name + "　" + preset.query, key: "") { [weak self] in
                var searches = Preferences.savedSearches
                var names = Preferences.savedSearchNames
                if searches.contains(preset.query) {
                    searches.removeAll { $0 == preset.query }
                    names[preset.query] = nil
                } else {
                    searches.append(preset.query)
                    names[preset.query] = preset.name
                }
                Preferences.savedSearches = searches
                Preferences.savedSearchNames = names
                self?.runSearch()
            }
            item.state = saved ? .on : .off
            item.toolTip = preset.detail
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "全部加入收藏", key: "") { [weak self] in
            var searches = Preferences.savedSearches
            var names = Preferences.savedSearchNames
            for preset in SavedSearchPresets.all where !searches.contains(preset.query) {
                searches.append(preset.query)
                names[preset.query] = preset.name
            }
            Preferences.savedSearches = searches
            Preferences.savedSearchNames = names
            self?.runSearch()
        })
        let row = max(0, table.selectedRow)
        let rect = table.rect(ofRow: row)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + 40, y: rect.maxY), in: table)
    }

    /// Searches that led somewhere: remembered when a result is opened or revealed.
    private func rememberSearch() {
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let saved = Preferences.savedSearches
        var rows = saved.map { text in
            ResultItem(path: "saved:" + text, name: names[text] ?? text, isFolder: false, score: 0,
                       fill: QueryFill(text: text, replace: true, select: nil, explanation: names[text] == nil ? "收藏的搜索" : "收藏的搜索：\(text)", isSaved: true))
        }
        // 新功能提示 (0.42): one example of the syntax, a different one each time.
        if Preferences.showTips, !SyntaxHelp.entries.isEmpty {
            let entry = SyntaxHelp.entries[Preferences.nextTip % SyntaxHelp.entries.count]
            rows.append(ResultItem(path: "tip:", name: "试试：" + entry.example, isFolder: false, score: 0,
                                   fill: QueryFill(text: entry.example, replace: true, select: entry.select, explanation: "提示 · " + entry.explanation)))
        }
        // Preset searches not yet added (0.35).
        let missing = SavedSearchPresets.all.filter { !saved.contains($0.query) }
        if !missing.isEmpty {
            rows.append(ResultItem(path: "presets:", name: "添加常用收藏搜索…", isFolder: false, score: 0,
                                   fill: QueryFill(text: "", replace: true, select: nil,
                                                   explanation: missing.prefix(4).map(\.name).joined(separator: "、") + "等，选一项即加入收藏",
                                                   isPresetPicker: true)))
        }
        return rows
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
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
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
            var label: String?
            if let pages = try? DocumentText.read(url, firstPage: page ?? 1, maximumPages: page == nil ? 3_000 : 1, ocr: store) {
                source = pages.pages.joined(separator: "\n")
                label = page.flatMap { pages.label(ofPage: $0) }
            }
            // The page as printed in the book (0.27).
            let printed = ext == "pdf" ? page.map { Records.pageNumbers.printed(path: item.path, pdfPage: $0, label: label) } : nil
            let sentence = Quotation.sentence(in: source, needles: needles)
            let stem = EbookName.splitMark(url.deletingPathExtension().lastPathComponent).stem
            let origin: String
            var book: EbookName?
            if DuplicateFinder.bookExtensions.contains(ext) {
                let info = BookInfo.read(url)
                book = info.name
                origin = Citation.make(Preferences.citationStyle, name: info.name, fallbackTitle: info.name.title, page: page, pageLabel: printed?.text).text
            } else {
                origin = "《\(stem)》" + (printed.map { "第 \($0.text) 页" } ?? page.map { ext == "pptx" ? "第 \($0) 张幻灯片" : "第 \($0) 页" } ?? "")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let sentence else {
                    self.statusLabel.stringValue = "未能提取命中的句子"
                    return
                }
                if toKongReview {
                    let place = printed.map { "第 \($0.text) 页" } ?? page.map { ext == "pptx" ? "第 \($0) 张幻灯片" : "第 \($0) 页" }
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
        if !result.missing.isEmpty { message += "（缺" + result.missing.joined(separator: "、") + "；⌘K › 补全书目信息 可联网查找）" }
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
        if !item.isFolder {
            add("相关文件（其他版本、同一文件夹中最近改过的）") { [weak self] in self?.showRelated(item) }
        }
        add(item.note == nil ? "写备注…" : "修改备注…") { [weak self] in self?.editNote(item) }
        if !item.copies.isEmpty {
            // Copies with the same content, merged into this row (0.36).
            let copies = NSMenu()
            for path in item.copies {
                copies.addItem(ClosureMenuItem(title: Self.displayLocation(of: path) + "/" + (path as NSString).lastPathComponent, key: "") { [weak self] in
                    self?.hide()
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                })
            }
            copies.addItem(.separator())
            copies.addItem(ClosureMenuItem(title: "在访达中全部显示", key: "") { [weak self] in
                self?.hide()
                NSWorkspace.shared.activateFileViewerSelecting(([item.path] + item.copies).map { URL(fileURLWithPath: $0) })
            })
            let copiesItem = NSMenuItem(title: "内容相同的副本（\(item.copies.count)）", action: nil, keyEquivalent: "")
            copiesItem.submenu = copies
            menu.addItem(copiesItem)
        }
        let ext = (item.path as NSString).pathExtension.lowercased()
        let hitPage = self.hitPage(for: item)
        if !item.isFolder && ext == "pdf" {
            let reader = KongFolio.isReader ? "在 KongFolio 中" : "在阅读窗口中"
            add(hitPage.map { "\(reader)打开到第 \($0) 页" } ?? (KongFolio.isReader ? "在 KongFolio 中打开（接着上次读）" : "在阅读窗口中打开（含目录）"), "\r", [.option]) { [weak self] in self?.openAtHit(item) }
            if let hitPage {
                let printed = PageNumberPrompt.printed(path: item.path, pdfPage: hitPage)
                add("书上页码：\(printed.text)" + (printed.text == String(hitPage) ? "" : "（PDF 第 \(hitPage) 页）") + "，设置…", "") { [weak self] in
                    self?.hide()
                    PageNumberPrompt.ask(path: item.path, pdfPage: hitPage, current: printed)
                }
            }
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
            add("补全书目信息（出版地、出版社、年份）…") { [weak self] in
                self?.hide()
                BookLookupWindowController.shared.present(path: item.path)
            }
            let books = results.filter { $0.isFile && !$0.isInArchive && DuplicateFinder.bookExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }.map(\.path)
            if books.count > 1 {
                add("批量补全这次搜索中 \(books.count) 本书的书目信息…") { [weak self] in
                    self?.hide()
                    BatchBookLookupWindowController.shared.present(paths: books)
                }
            }
            let preferred = Records.editions.isPreferred(item.path)
            add(preferred ? "取消常用本" : "设为常用本（同书多个版本时，查证与汇编中排在最前）") { [weak self] in
                Records.togglePreferred(item.path)
                self?.statusLabel.stringValue = preferred ? "已取消常用本：\(item.name)" : "已设为常用本：\(item.name)"
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
        if contentMode {
            add("出处汇编：逐处列出这些词在各书中的位置…") { [weak self] in
                guard let self else { return }
                let text = self.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                self.hide()
                self.onConcordance?(text)
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
            label.stringValue = (item.path.hasPrefix("header:related:") ? "  " : "  📁 ") + item.name + "（\(item.score) 个）"
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
            let symbol = fill.isPresetPicker ? "plus.circle" : (fill.isSaved ? "star" : (fill.isHistory ? "clock.arrow.circlepath" : "text.magnifyingglass"))
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
            // A book's details and the reader's note first (0.40), then where it is.
            let leading = [item.bookLine, item.note.map { "📝 " + $0 }].compactMap { $0 }
            location = (leading.isEmpty ? "" : leading.joined(separator: "  ") + "  —  ")
                + Self.displayLocation(of: item.path) + (item.recognized ? " · 识别文字" : "") + (item.ownText ? " · KongSeek 正文索引" : "")
                + (item.copies.isEmpty ? "" : " · 另有 \(item.copies.count) 个副本（⌘K 查看）")
                + (item.hitCount.map { " · 命中 \($0) 处" } ?? "")
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
        if let selected { HangMonitor.note("预览：" + selected.name) }
        if let findPath = previewFindPath, findPath != selected?.path {
            previewFindPath = nil
            previewFindWords = nil
            previewFind.isHidden = true
            previewFind.stringValue = ""
        }
        if hitPreview.document?.documentURL?.path != selected?.path { hideHitPreview() }
        definitionScroll.isHidden = selected?.isFile ?? true
        if let item = selected, let fill = item.fill, fill.isPresetPicker {
            definitionView.string = "↩ 或双击：列出常用搜索，选一项加入收藏（再选一次移除）。\n\n" + SavedSearchPresets.all.map { "\($0.name)：\($0.query)\n  \($0.detail)" }.joined(separator: "\n")
            definitionView.scrollToBeginningOfDocument(nil)
        } else if let item = selected, let fill = item.fill {
            definitionView.string = fill.isSaved || fill.isHistory
                ? "↩ 搜索：\(fill.text)\n\n⌘⌫ " + (fill.isSaved ? "从收藏中移除。在任意搜索时按 ⌘S 可收藏当前搜索。" : "从搜索历史中删除。在 设置 › 搜索 可关闭或清除搜索历史。")
                : "\(fill.text)\n\n\(fill.explanation)\n\n↩ 或单击：加入搜索框" + (fill.select.map { "，并选中“\($0)”方便直接改写" } ?? "") + "。"
            definitionView.scrollToBeginningOfDocument(nil)
        } else if let item = selected, !item.isFile {
            definitionView.string = item.definition.map { $0.isEmpty ? "系统词典中没有“\(item.name)”。\n可在“词典”App 的设置中启用更多词典（如现代汉语词典、牛津英汉汉英词典），或用汉典查询。" : $0 }
                ?? "↩ 在浏览器中打开：\n\(item.link?.absoluteString ?? "")"
            definitionView.scrollToBeginningOfDocument(nil)
        }
        var url = selected.flatMap(previewURL(for:))
        // E-books (0.39): their text in place of Quick Look, which shows little of them.
        if let item = selected, Self.isEbook(item) {
            url = nil
            showEbookPreview(item)
        }
        if let item = selected, item.isInArchive { loadArchivePreview(item) }
        if (preview.previewItem as? NSURL).map({ $0 as URL }) != url {
            preview.previewItem = url as NSURL?
        }
        updateSnippet()
    }

    static func isEbook(_ item: ResultItem) -> Bool {
        item.isFile && !item.isFolder && !item.isInArchive && EbookText.supports((item.path as NSString).pathExtension)
    }

    /// The opening of an e-book's text in the preview area (0.39), from the text index
    /// when it is there; a hit's passage replaces it once the hits are found.
    private func showEbookPreview(_ item: ResultItem) {
        ebookPreviewToken += 1
        let token = ebookPreviewToken
        definitionScroll.isHidden = false
        definitionView.string = "正在读取“\(item.name)”…"
        let path = item.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var text = BookTextService.shared.index.pages(for: path)?.joined(separator: "\n\n")
            if text == nil, (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus != .notDownloaded {
                text = (try? EbookText.read(URL(fileURLWithPath: path)))?.joined(separator: "\n\n")
            }
            let opening = text.map { $0.count > 4_000 ? String($0.prefix(4_000)) + "\n\n……" : $0 }
            DispatchQueue.main.async {
                guard let self, token == self.ebookPreviewToken, self.selectedItem?.path == path else { return }
                if let list = self.hitList, list.path == path { return }
                let body = opening ?? "读不出这本书的文字（可能有 DRM 保护，或只在 iCloud 中）。"
                let result = NSMutableAttributedString(string: item.name + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
                result.append(NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]))
                for range in TextLocator.ranges(of: self.outcome.highlightWords, in: result.string) {
                    result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4), range: range)
                }
                self.definitionView.textStorage?.setAttributedString(result)
                self.definitionView.scrollToBeginningOfDocument(nil)
            }
        }
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
                    self.findAllHits(item.path, needles: needles, firstPage: place.page, token: token)
                } else {
                    self.hideHitPreview()
                }
                self.snippetLabel.attributedStringValue = Self.snippetText(found)
            }
        }
    }

    /// Every place the words occur in the file (0.36), read in the background; then
    /// ⌘] and ⌘[ step through them and ⌘J lists them.
    private func findAllHits(_ path: String, needles: [String], firstPage: Int?, token: Int) {
        let store = ocr.store
        hitList = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var places: [HitPlace] = []
            if let pages = QuoteLookup.readCached(URL(fileURLWithPath: path), ocr: store) {
                // E-books get long passages (0.39), shown whole in the preview area.
                let radius = EbookText.supports((path as NSString).pathExtension) ? 400 : 60
                for (index, text) in pages.pages.enumerated() where places.count < 300 {
                    for snippet in Snippet.findAll(in: text, needles: needles, radius: radius, limit: radius > 60 ? 300 : 20) where places.count < 300 {
                        places.append(HitPlace(page: pages.isPaged ? pages.firstPage + index : nil, snippet: snippet))
                    }
                }
            }
            DispatchQueue.main.async {
                let ebook = EbookText.supports((path as NSString).pathExtension)
                guard let self, token == self.snippetToken, self.selectedItem?.path == path, self.previewFindWords == nil,
                      places.count > (ebook ? 0 : 1) else { return }
                self.hitList = (path, places)
                self.hitPosition = places.firstIndex { $0.page == firstPage } ?? 0
                self.showHitPlace()
            }
        }
    }

    /// Shows the current hit of `hitList`: its passage, and its page in the preview.
    private func showHitPlace() {
        guard let list = hitList, list.places.indices.contains(hitPosition) else { return }
        let place = list.places[hitPosition]
        lastHit = (list.path, place.page)
        let words = previewFindWords ?? outcome.highlightWords
        showHitPage(list.path, page: place.page, words: words)
        let ebook = EbookText.supports((list.path as NSString).pathExtension)
        if ebook {
            // The whole passage in the preview area, the words in yellow (0.39).
            let passage = NSMutableAttributedString(string: place.snippet.text, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
            for range in TextLocator.ranges(of: words, in: place.snippet.text) {
                passage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4), range: range)
            }
            definitionScroll.isHidden = false
            definitionView.textStorage?.setAttributedString(passage)
            definitionView.scrollRangeToVisible(place.snippet.highlight)
        }
        let shown = ebook ? place.snippet.trimmed(radius: 60) : place.snippet
        let text = NSMutableAttributedString(attributedString: Self.placeText(page: place.page, recognized: false, snippet: shown))
        text.append(NSAttributedString(string: "\n第 \(hitPosition + 1) / \(list.places.count) 处\(list.places.count >= 300 ? "（只列前 300 处）" : "") · ⌘] 下一处 · ⌘[ 上一处 · ⌘J 列出全部",
                                       attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        snippetLabel.attributedStringValue = text
    }

    // MARK: Find in the preview (0.43)

    private func openPreviewFind() -> Bool {
        guard let item = selectedItem, item.isFile, !item.isFolder, !item.isInArchive, ContentPreview.canRead(item.path) else { return false }
        previewFind.isHidden = false
        previewFindPath = item.path
        panel.makeFirstResponder(previewFind)
        statusLabel.stringValue = "在“\(item.name)”中查找：输入后按 ↩；⌘] ⌘[ 前后跳转；⎋ 关闭"
        return true
    }

    private func closePreviewFind() {
        let wasFinding = previewFindWords != nil
        previewFind.isHidden = true
        previewFind.stringValue = ""
        previewFindWords = nil
        previewFindPath = nil
        panel.makeFirstResponder(field)
        field.currentEditor()?.moveToEndOfDocument(nil)
        if wasFinding {
            hitList = nil
            updatePreview()
        }
    }

    @objc private func previewFindSubmitted() {
        let term = previewFind.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = selectedItem, item.isFile, !term.isEmpty else { return }
        let path = item.path
        let name = item.name
        let words = term.split(separator: " ").map(String.init)
        statusLabel.stringValue = "正在“\(name)”中查找“\(term)”…"
        let store = ocr.store
        let ebook = EbookText.supports((path as NSString).pathExtension)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var places: [HitPlace] = []
            if let pages = QuoteLookup.readCached(URL(fileURLWithPath: path), ocr: store) {
                for (index, text) in pages.pages.enumerated() where places.count < 300 {
                    for snippet in Snippet.findAll(in: text, needles: words, radius: ebook ? 400 : 60, limit: ebook || !pages.isPaged ? 300 : 20) where places.count < 300 {
                        places.append(HitPlace(page: pages.isPaged ? pages.firstPage + index : nil, snippet: snippet))
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.selectedItem?.path == path else { return }
                guard !places.isEmpty else {
                    self.statusLabel.stringValue = "“\(name)”中没有找到“\(term)”"
                    return
                }
                self.previewFindWords = words
                self.hitList = (path, places)
                self.hitPosition = 0
                if !self.contentMode { self.setNameSnippetVisible(true) }
                self.showHitPlace()
                self.statusLabel.stringValue = "在“\(name)”中找到 \(places.count) 处“\(term)” · ⌘] ⌘[ 跳转 · ⌘J 列出 · ⎋ 关闭"
            }
        }
    }

    private func stepHit(_ delta: Int) -> Bool {
        guard let list = hitList, list.path == selectedItem?.path, !list.places.isEmpty else { return false }
        hitPosition = (hitPosition + delta + list.places.count) % list.places.count
        showHitPlace()
        return true
    }

    private func showHitMenu() -> Bool {
        guard let list = hitList, list.path == selectedItem?.path, !list.places.isEmpty else { return false }
        let menu = NSMenu()
        for (index, place) in list.places.enumerated() {
            let brief = place.snippet.trimmed(radius: 18).text
            let passage = brief.count > 44 ? String(brief.prefix(44)) + "…" : brief
            let entry = ClosureMenuItem(title: (place.page.map { "第 \($0) 页　" } ?? "") + passage, key: "") { [weak self] in
                self?.hitPosition = index
                self?.showHitPlace()
            }
            entry.state = index == hitPosition ? .on : .off
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 8, y: snippetLabel.bounds.height), in: snippetLabel)
        return true
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

    /// A hit's page and passage, the matched words in yellow.
    private static func placeText(page: Int?, recognized: Bool, snippet: Snippet) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let note: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        let result = NSMutableAttributedString()
        if let page {
            result.append(NSAttributedString(string: "第 \(page) 页", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.controlAccentColor]))
            result.append(NSAttributedString(string: "（⌥↩ 打开到此处，⌘K 拷贝引文）  ", attributes: note))
        }
        if recognized {
            result.append(NSAttributedString(string: "识别文字  ", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.systemOrange]))
        }
        let start = result.length
        result.append(NSAttributedString(string: snippet.text, attributes: base))
        let range = NSRange(location: start + snippet.highlight.location, length: snippet.highlight.length)
        result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4), range: range)
        return result
    }

    private static func snippetText(_ outcome: ContentPreview.Outcome) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let note: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        switch outcome {
        case .found(let found):
            _ = base
            return placeText(page: found.page, recognized: found.recognized, snippet: found.snippet)
        case .notFound:
            return NSAttributedString(string: "Spotlight 认为此文件匹配，但未能定位原文（可能命中的是元数据，或词语被分隔）。", attributes: note)
        case .notDownloaded:
            return NSAttributedString(string: "此文件在 iCloud 中尚未下载到本机，不读取正文。", attributes: note)
        case .unsupported:
            return NSAttributedString(string: "此类文件不显示命中原文（支持 PDF、Word、RTF、EPUB、Kindle 与纯文本）。", attributes: note)
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
