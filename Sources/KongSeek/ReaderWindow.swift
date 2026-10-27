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
    private var keyMonitor: Any?

    /// The page each PDF was last read at (path → 1-based page), so it reopens there (0.19).
    private static let pagesKey = "readerPages"
    private static var savedPages: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: pagesKey) as? [String: Int] ?? [:] }
        set {
            var pages = newValue
            if pages.count > 500 { pages = Dictionary(uniqueKeysWithValues: pages.prefix(400).map { ($0.key, $0.value) }) }
            UserDefaults.standard.set(pages, forKey: pagesKey)
        }
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("KongSeekReader")
        super.init(window: window)
        window.delegate = self
        build()
        // ⌘F find, ⌘+ / ⌘− / ⌘0 zoom, ⌘W close: KongSeek has no menu bar of its own to carry them.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function, .shift])
        guard modifiers == [.command] else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f":
            window?.makeFirstResponder(findField)
            return true
        case "=", "+":
            zoomIn()
            return true
        case "-":
            zoomOut()
            return true
        case "0":
            pdfView.autoScales = true
            return true
        case "w":
            window?.performClose(nil)
            return true
        default:
            return false
        }
    }

    @objc private func zoomIn() { pdfView.zoomIn(nil) }
    @objc private func zoomOut() { pdfView.zoomOut(nil) }

    /// Remembers where the current PDF was being read.
    private func rememberPage() {
        guard let url, let document = pdfView.document, let page = pdfView.currentPage else { return }
        Self.savedPages[url.path] = document.index(for: page) + 1
    }

    func windowWillClose(_ notification: Notification) {
        rememberPage()
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
        findField.placeholderString = "在此 PDF 中查找（⌘F）"
        findField.delegate = self
        findField.sendsWholeSearchString = true
        findField.target = self
        findField.action = #selector(find)
        let zoomOutButton = NSButton(title: "−", target: self, action: #selector(zoomOut))
        let zoomInButton = NSButton(title: "+", target: self, action: #selector(zoomIn))
        zoomOutButton.toolTip = "缩小（⌘−）"
        zoomInButton.toolTip = "放大（⌘+）；⌘0 适合窗口"
        for button in [zoomOutButton, zoomInButton] { button.bezelStyle = .texturedRounded }
        let previewButton = NSButton(title: "用“预览”打开", target: self, action: #selector(openInPreview))
        let revealButton = NSButton(title: "在访达中显示", target: self, action: #selector(reveal))
        for button in [previewButton, revealButton] { button.bezelStyle = .texturedRounded }
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail

        let bar = NSStackView(views: [outlineButton, pageLabel, messageLabel, NSView(), zoomOutButton, zoomInButton, findField, previewButton, revealButton])
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
        rememberPage()
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
                // Without a hit, continue where this PDF was last read.
                self.show(document, page: page ?? Self.savedPages[url.path], words: page == nil ? [] : words)
            }
        }
    }

    private func show(_ document: PDFDocument, page: Int?, words: [String]) {
        pdfView.document = document
        outlineRoot = document.outlineRoot
        outlineView.reloadData()
        let outlineCount = outlineRoot?.numberOfChildren ?? 0
        setOutlineVisible(outlineCount > 0)
        outlineButton.isEnabled = outlineCount > 0
        let outlineNote = outlineCount > 0 ? "左侧目录 \(outlineCount) 项" : "此 PDF 没有目录（书签）"
        var target: PDFPage?
        if let page, page >= 1, page <= document.pageCount { target = document.page(at: page - 1) }
        // Only the target page is searched, so a long book opens at once; line breaks
        // inside the words are allowed (TextLocator).
        var marks: [PDFSelection] = []
        if let target, let text = target.string {
            marks = TextLocator.ranges(of: words, in: text).compactMap { target.selection(for: $0) }
        }
        for mark in marks { mark.color = .systemYellow }
        pdfView.highlightedSelections = marks.isEmpty ? nil : marks
        if let first = marks.first {
            pdfView.go(to: first)
        } else if let target {
            pdfView.go(to: target)
        }
        // Say plainly what happened, so it is clear whether this is the hit.
        var parts: [String] = []
        if let page, target != nil, words.isEmpty {
            parts.append("接着上次读到的第 \(page) 页")
        } else if let page, target != nil {
            let shown = words.joined(separator: " ")
            parts.append(marks.isEmpty
                ? "命中在第 \(page) 页；此页的文字层中没有“\(shown)”（多为扫描页，命中来自识别文字），未能标黄"
                : "命中在第 \(page) 页，已标黄 \(marks.count) 处")
        }
        parts.append(outlineNote)
        messageLabel.stringValue = parts.joined(separator: " · ")
        messageLabel.toolTip = messageLabel.stringValue
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
