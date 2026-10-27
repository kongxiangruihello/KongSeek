import AppKit
import KongSeekCore

/// Settings page for text snippets: list on the left, editor on the right.
final class SnippetSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    private let library: SnippetLibrary
    private let expansion: SnippetExpansionService
    private let table = NSTableView()
    private let nameField = NSTextField()
    private let keywordField = NSTextField()
    private let contentScroll = NSTextView.scrollableTextView()
    private var contentView: NSTextView { contentScroll.documentView as! NSTextView }
    private let expansionCheckbox = NSButton(checkboxWithTitle: "在任何应用中输入关键词时自动替换为片段", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var rows: [TextSnippet] = []
    private var observer: NSObjectProtocol?
    private var saveWork: DispatchWorkItem?

    init(library: SnippetLibrary, expansion: SnippetExpansionService) {
        self.library = library
        self.expansion = expansion
        super.init(frame: .zero)
        build()
        observer = NotificationCenter.default.addObserver(forName: SnippetLibrary.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadKeepingSelection()
        }
        reloadKeepingSelection()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("snippet"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: "新建", target: self, action: #selector(addSnippet))
        let remove = NSButton(title: "删除", target: self, action: #selector(removeSnippet))
        let nameLabel = NSTextField(labelWithString: "名称：")
        let keywordLabel = NSTextField(labelWithString: "关键词：")
        let contentLabel = NSTextField(labelWithString: "内容：")
        for field in [nameField, keywordField] {
            field.delegate = self
        }
        keywordField.placeholderString = "如 ;lk（至少两个字符，不含空格）"
        contentView.isRichText = false
        contentView.font = .systemFont(ofSize: 13)
        contentView.delegate = self
        contentView.isAutomaticQuoteSubstitutionEnabled = false
        contentView.isAutomaticDashSubstitutionEnabled = false
        contentScroll.borderType = .bezelBorder
        contentScroll.hasVerticalScroller = true

        let help = NSTextField(wrappingLabelWithString: "占位符：" + SnippetTemplate.placeholders.map { "\($0.token) \($0.meaning)" }.joined(separator: "；")
            + "。剪贴板窗口（⌃⌥V）中按 ⇥ 切换到片段，↩ 粘贴。")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 470
        expansionCheckbox.target = self
        expansionCheckbox.action = #selector(expansionChanged)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.preferredMaxLayoutWidth = 470

        let views: [NSView] = [scroll, add, remove, nameLabel, nameField, keywordLabel, keywordField, contentLabel, contentScroll, help, expansionCheckbox, statusLabel]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.widthAnchor.constraint(equalToConstant: 160),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -6),
            add.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            add.bottomAnchor.constraint(equalTo: help.topAnchor, constant: -10),
            remove.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 6),
            remove.centerYAnchor.constraint(equalTo: add.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 14),
            nameLabel.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            nameLabel.widthAnchor.constraint(equalToConstant: 56),
            nameField.topAnchor.constraint(equalTo: scroll.topAnchor),
            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 4),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            keywordLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            keywordLabel.centerYAnchor.constraint(equalTo: keywordField.centerYAnchor),
            keywordLabel.widthAnchor.constraint(equalTo: nameLabel.widthAnchor),
            keywordField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 8),
            keywordField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            keywordField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            contentLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            contentLabel.topAnchor.constraint(equalTo: keywordField.bottomAnchor, constant: 10),
            contentScroll.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: 4),
            contentScroll.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            contentScroll.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            contentScroll.bottomAnchor.constraint(equalTo: add.bottomAnchor),

            help.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            help.bottomAnchor.constraint(equalTo: expansionCheckbox.topAnchor, constant: -8),
            expansionCheckbox.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            expansionCheckbox.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            statusLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    // MARK: Data

    private var selected: TextSnippet? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    private func reloadKeepingSelection() {
        let id = selected?.id
        rows = library.snippets
        table.reloadData()
        let index = id.flatMap { id in rows.firstIndex { $0.id == id } } ?? (rows.isEmpty ? -1 : 0)
        if index >= 0 { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        showSelected()
        refreshStatus()
    }

    func refreshStatus() {
        expansionCheckbox.state = Preferences.snippetExpansion ? .on : .off
        var notes: [String] = []
        let duplicates = library.duplicateKeywords
        if !duplicates.isEmpty { notes.append("关键词重复：" + duplicates.joined(separator: "、") + "（只有一个会生效）") }
        let invalid = library.snippets.map(\.keyword).filter { !$0.isEmpty && !TextSnippet.isValidKeyword($0) }
        if !invalid.isEmpty { notes.append("关键词至少两个字符且不含空格，无效：" + invalid.joined(separator: "、")) }
        if Preferences.snippetExpansion {
            if !CGPreflightListenEventAccess() {
                notes.append("自动替换需要“输入监控”权限（与连按 Control 相同）")
            } else if !Paster.isTrusted {
                notes.append("自动替换需要“辅助功能”权限（设置 › 剪贴板 中授予）")
            } else if let problem = expansion.lastProblem {
                notes.append(problem)
            } else if expansion.isListening {
                notes.append(expansion.inputMethodActive ? "正在监听。使用输入法时，英文状态下输入关键词即可" : "正在监听关键词")
            }
        }
        statusLabel.stringValue = notes.joined(separator: "；")
        statusLabel.textColor = duplicates.isEmpty && invalid.isEmpty ? .secondaryLabelColor : .systemOrange
    }

    private func showSelected() {
        let snippet = selected
        for field in [nameField, keywordField] { field.isEnabled = snippet != nil }
        contentView.isEditable = snippet != nil
        // Only touch fields whose text differs, so typing is not interrupted after a save.
        if nameField.stringValue != (snippet?.name ?? "") { nameField.stringValue = snippet?.name ?? "" }
        if keywordField.stringValue != (snippet?.keyword ?? "") { keywordField.stringValue = snippet?.keyword ?? "" }
        if contentView.string != (snippet?.content ?? "") { contentView.string = snippet?.content ?? "" }
    }

    /// Saves the editor into the selected snippet (shortly after typing stops).
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveNow() {
        guard var snippet = selected else { return }
        let keyword = keywordField.stringValue.trimmingCharacters(in: .whitespaces)
        snippet.name = nameField.stringValue
        // Saved as typed; keywords that are too short or contain spaces simply never expand.
        snippet.keyword = keyword
        snippet.content = contentView.string
        guard snippet != selected else { return }
        library.upsert(snippet)
    }

    func controlTextDidChange(_ obj: Notification) {
        scheduleSave()
    }

    func textDidChange(_ notification: Notification) {
        scheduleSave()
    }

    // MARK: Actions

    @objc private func addSnippet() {
        saveNow()
        let snippet = TextSnippet(name: "新片段", content: "")
        library.upsert(snippet)
        if let index = rows.firstIndex(where: { $0.id == snippet.id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            showSelected()
            window?.makeFirstResponder(nameField)
            nameField.currentEditor()?.selectAll(nil)
        }
    }

    @objc private func removeSnippet() {
        guard let snippet = selected else { return }
        saveWork?.cancel()
        library.remove(snippet.id)
    }

    @objc private func expansionChanged() {
        Preferences.snippetExpansion = expansionCheckbox.state == .on
        expansion.enabled = Preferences.snippetExpansion
        if Preferences.snippetExpansion && !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        refreshStatus()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let snippet = rows[row]
        let title = NSTextField(labelWithString: snippet.name.isEmpty ? "（未命名）" : snippet.name)
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: snippet.keyword.isEmpty ? "无关键词" : snippet.keyword)
        subtitle.font = .systemFont(ofSize: 10.5)
        subtitle.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showSelected()
    }

    func selectionShouldChange(in tableView: NSTableView) -> Bool {
        saveWork?.cancel()
        saveNow()
        return true
    }
}
