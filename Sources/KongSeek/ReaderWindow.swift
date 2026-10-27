import AppKit
import PDFKit
import KongSeekCore

/// A small PDF reader (0.18): opens at the page a full-text search hit, with the
/// words highlighted, and the PDF's own table of contents (bookmarks) beside it.
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    static let shared = ReaderWindowController()

    private let pdfView = PDFView()
    private let outlineView = NSOutlineView()
    private let outlineScroll = NSScrollView()
    private let split = NSSplitView()
    private let pageLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let findField = NSSearchField()
    private let outlineButton = NSButton()
    private var url: URL?
    private var outlineRoot: PDFOutline?
    private var loadToken = 0
    private var findResults: [PDFSelection] = []
    private var findIndex = 0
    private var lastFind = ""

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("KongSeekReader")
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.title = "目录"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowSizeStyle = .small
        outlineView.target = self
        outlineView.action = #selector(outlineClicked)
        outlineScroll.documentView = outlineView
        outlineScroll.hasVerticalScroller = true

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(outlineScroll)
        split.addArrangedSubview(pdfView)
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 1)

        outlineButton.bezelStyle = .texturedRounded
        outlineButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "目录")
        outlineButton.toolTip = "显示或隐藏目录"
        outlineButton.target = self
        outlineButton.action = #selector(toggleOutline)
        findField.placeholderString = "在此 PDF 中查找"
        findField.delegate = self
        findField.sendsWholeSearchString = true
        findField.target = self
        findField.action = #selector(find)
        let previewButton = NSButton(title: "用“预览”打开", target: self, action: #selector(openInPreview))
        let revealButton = NSButton(title: "在访达中显示", target: self, action: #selector(reveal))
        for button in [previewButton, revealButton] { button.bezelStyle = .texturedRounded }
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail

        let bar = NSStackView(views: [outlineButton, pageLabel, messageLabel, NSView(), findField, previewButton, revealButton])
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        findField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        for view in [bar, split] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            outlineScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    // MARK: Opening

    /// Opens `url` at `page` (1-based), highlighting `words` on that page if the PDF has text there.
    func open(_ url: URL, page: Int?, words: [String]) {
        self.url = url
        loadToken += 1
        let token = loadToken
        window?.title = url.lastPathComponent
        window?.representedURL = url
        pdfView.document = nil
        outlineRoot = nil
        outlineView.reloadData()
        findResults = []
        pageLabel.stringValue = ""
        messageLabel.stringValue = "正在打开…"
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let document = PDFDocument(url: url)
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                guard let document else {
                    self.messageLabel.stringValue = "无法打开这个 PDF。"
                    return
                }
                self.show(document, page: page, words: words)
            }
        }
    }

    private func show(_ document: PDFDocument, page: Int?, words: [String]) {
        pdfView.document = document
        outlineRoot = document.outlineRoot
        outlineView.reloadData()
        let hasOutline = (outlineRoot?.numberOfChildren ?? 0) > 0
        setOutlineVisible(hasOutline)
        outlineButton.isEnabled = hasOutline
        messageLabel.stringValue = hasOutline ? "" : "此 PDF 没有目录（书签）"
        var target: PDFPage?
        if let page, page >= 1, page <= document.pageCount { target = document.page(at: page - 1) }
        // Only the target page is searched, so a long book opens at once.
        var marks: [PDFSelection] = []
        if let target, let text = target.string {
            for word in words.flatMap(SearchText.scriptVariants) where !word.isEmpty {
                var from = text.startIndex
                while from < text.endIndex, let range = text.range(of: word, options: [.caseInsensitive, .widthInsensitive], range: from..<text.endIndex) {
                    if let selection = target.selection(for: NSRange(range, in: text)) { marks.append(selection) }
                    from = range.upperBound
                }
            }
        }
        for mark in marks { mark.color = .systemYellow }
        pdfView.highlightedSelections = marks.isEmpty ? nil : marks
        if let first = marks.first {
            pdfView.go(to: first)
        } else if let target {
            pdfView.go(to: target)
            if !words.isEmpty, let page { messageLabel.stringValue = "命中在第 \(page) 页（扫描页的识别文字无法在页面上标出）" }
        }
        pageChanged()
    }

    // MARK: Actions

    @objc private func pageChanged() {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return }
        pageLabel.stringValue = "第 \(document.index(for: page) + 1) / \(document.pageCount) 页"
    }

    @objc private func toggleOutline() {
        setOutlineVisible(outlineScroll.isHidden)
    }

    private func setOutlineVisible(_ visible: Bool) {
        outlineScroll.isHidden = !visible
        split.adjustSubviews()
        if visible { split.setPosition(240, ofDividerAt: 0) }
    }

    @objc private func outlineClicked() {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? PDFOutline else { return }
        if let destination = item.destination {
            pdfView.go(to: destination)
        } else if let action = item.action as? PDFActionGoTo {
            pdfView.go(to: action.destination)
        }
    }

    @objc private func find() {
        guard let document = pdfView.document else { return }
        let text = findField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            findResults = []
            pdfView.highlightedSelections = nil
            return
        }
        if findResults.isEmpty || text != lastFind {
            lastFind = text
            findResults = SearchText.scriptVariants(text).flatMap { document.findString($0, withOptions: [.caseInsensitive]) }
                .sorted { a, b in
                    let pa = a.pages.first.map(document.index(for:)) ?? 0, pb = b.pages.first.map(document.index(for:)) ?? 0
                    return pa < pb
                }
            findIndex = 0
            for result in findResults { result.color = .systemYellow }
            pdfView.highlightedSelections = findResults.isEmpty ? nil : findResults
        } else {
            findIndex = (findIndex + 1) % findResults.count
        }
        guard !findResults.isEmpty else {
            messageLabel.stringValue = "没有找到“\(text)”"
            return
        }
        let current = findResults[findIndex]
        pdfView.go(to: current)
        pdfView.setCurrentSelection(current, animate: true)
        messageLabel.stringValue = "第 \(findIndex + 1) / \(findResults.count) 处（↩ 下一处）"
    }

    @objc private func openInPreview() {
        guard let url else { return }
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func reveal() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Outline data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? PDFOutline) ?? outlineRoot)?.numberOfChildren ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? PDFOutline) ?? outlineRoot)?.child(at: index) ?? PDFOutline()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        ((item as? PDFOutline)?.numberOfChildren ?? 0) > 0
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let label = NSTextField(labelWithString: (item as? PDFOutline)?.label ?? "")
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        label.toolTip = label.stringValue
        return label
    }
}
