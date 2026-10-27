import AppKit
import Quartz
import KongSeekCore

/// A floating panel that takes keyboard input without activating KongSeek,
/// so the app the user was in stays in front.
final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The search window: query field, results list, Quick Look preview, status line.
final class SearchWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let panel: SearchPanel
    private let service: IndexService
    private let field = NSTextField()
    private let table = NSTableView()
    private let preview: QLPreviewView
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private var results: [ResultItem] = []
    private var outcome = SearchOutcome()
    private var keyMonitor: Any?
    private let icons = NSCache<NSString, NSImage>()
    /// When the panel was last shown, and how often it took focus back since then.
    private var shownAt = Date.distantPast
    private var focusReclaims = 0

    private static let width: CGFloat = 800
    private static let height: CGFloat = 500

    init(service: IndexService) {
        self.service = service
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

    func hide() {
        removeKeyMonitor()
        preview.previewItem = nil
        panel.orderOut(nil)
    }

    /// Hides the panel when the user moves to another window. Right after it is
    /// shown, macOS can hand keyboard focus straight back to the app that was in
    /// front (seen on the first ⌥Space after launch); the panel then takes focus
    /// back instead of disappearing.
    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
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
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
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

        let searchIcon = NSImageView()
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "搜索")
        searchIcon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        searchIcon.contentTintColor = .secondaryLabelColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.placeholderString = "搜索文件名、拼音或首字母    ext:pdf    \"短语\"    -排除"
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
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.refusesFirstResponder = true

        let scroll = NSScrollView()
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
        let hints = NSTextField(labelWithString: "↩ 打开   ⌘↩ 在访达中显示   ⌘C 拷贝   ⌥⌘C 拷贝路径   ⌘1–9 打开第几项")
        hints.font = .systemFont(ofSize: 11)
        hints.textColor = .tertiaryLabelColor
        hints.alignment = .right
        hints.lineBreakMode = .byTruncatingHead

        for view in [searchIcon, field, topLine, scroll, middleLine, preview, emptyLabel, bottomLine, statusLabel, hints] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hints.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            searchIcon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 22),

            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
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

            preview.topAnchor.constraint(equalTo: topLine.bottomAnchor, constant: 8),
            preview.leadingAnchor.constraint(equalTo: middleLine.trailingAnchor, constant: 8),
            preview.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            preview.bottomAnchor.constraint(equalTo: bottomLine.topAnchor, constant: -8),

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
        updateEmptyLabel()
    }

    // MARK: - Searching

    func controlTextDidChange(_ obj: Notification) {
        // Wait while a Chinese input method is still composing.
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        runSearch()
    }

    func runSearch() {
        service.search(field.stringValue, precision: Preferences.precision) { [weak self] outcome in
            self?.show(outcome)
        }
    }

    private func show(_ newOutcome: SearchOutcome) {
        outcome = newOutcome
        results = newOutcome.items
        table.reloadData()
        if !results.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        updatePreview()
        updateEmptyLabel()
        updateStatus()
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
        switch service.state {
        case .loading where !text.isEmpty:
            emptyLabel.stringValue = "正在载入索引…"
        case .building(let entries) where !text.isEmpty:
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
            parts.append("正在建立索引 · \(entries.formatted()) 项")
        case .ready(let entries, _):
            parts.append("已索引 \(entries.formatted()) 项")
        }
        if outcome.isRecentList {
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
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            openSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { hide() } else {
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
        if modifiers == [.command] {
            switch keyCode {
            case 36, 76: // Return, Enter
                revealSelected()
                return true
            case 51: // Delete: remove from the recent list
                guard outcome.isRecentList, let item = selectedItem else { return false }
                Preferences.forget(item.path)
                runSearch()
                return true
            case 31: // O
                openSelected()
                return true
            case 8: // C: copy the file unless text is selected in the field
                if let editor = field.currentEditor(), editor.selectedRange.length > 0 { return false }
                copySelected(asPath: false)
                return true
            default:
                if let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...9).contains(digit) {
                    open(row: digit - 1)
                    return true
                }
            }
        }
        if modifiers == [.command, .option], keyCode == 8 {
            copySelected(asPath: true)
            return true
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = table.selectedRow
        let next = max(0, min(results.count - 1, (current < 0 ? 0 : current + delta)))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
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
        guard row >= 0 && row < results.count else { return }
        let item = results[row]
        Preferences.recordOpen(item.path)
        hide()
        NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
    }

    private func revealSelected() {
        guard let item = selectedItem else { return }
        Preferences.recordOpen(item.path)
        hide()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    private func copySelected(asPath: Bool) {
        guard let item = selectedItem else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if asPath {
            pasteboard.setString(item.path, forType: .string)
        } else {
            pasteboard.writeObjects([URL(fileURLWithPath: item.path) as NSURL])
        }
        statusLabel.stringValue = asPath ? "已拷贝路径：\(item.path)" : "已拷贝文件：\(item.name)"
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ResultCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? ResultCellView) ?? ResultCellView(identifier: identifier)
        let item = results[row]
        cell.configure(
            name: highlighted(item.name),
            location: Self.displayLocation(of: item.path),
            icon: icon(for: item.path),
            shortcut: row < 9 ? "⌘\(row + 1)" : ""
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    private func updatePreview() {
        if let item = selectedItem {
            preview.previewItem = URL(fileURLWithPath: item.path) as NSURL
        } else {
            preview.previewItem = nil
        }
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
