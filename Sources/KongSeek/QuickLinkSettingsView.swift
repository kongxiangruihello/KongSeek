import AppKit
import KongSeekCore

/// Settings page for web search keywords ("hd 仁") and the dictionary lookup shortcut.
final class QuickLinkSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let lookupHotKey: HotKey
    private let table = NSTableView()
    private let recorder = ShortcutRecorderButton()
    private let lookupNote = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var links: [QuickLink] = []

    private enum Column: String, CaseIterable {
        case keyword, name, template, fallback

        var title: String {
            switch self {
            case .keyword: return "关键词"
            case .name: return "名称"
            case .template: return "网址（{query} 处填入搜索词）"
            case .fallback: return "兜底"
            }
        }

        var width: CGFloat {
            switch self {
            case .keyword: return 56
            case .name: return 110
            case .template: return 250
            case .fallback: return 40
            }
        }
    }

    init(lookupHotKey: HotKey) {
        self.lookupHotKey = lookupHotKey
        super.init(frame: .zero)
        build()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func build() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: "添加", target: self, action: #selector(addLink))
        let remove = NSButton(title: "删除", target: self, action: #selector(removeLink))
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetLinks))
        let help = NSTextField(wrappingLabelWithString: "在搜索窗口输入“关键词 + 空格 + 内容”，如 hd 仁、ct 学而，↩ 打开。找不到文件时，列出勾选了“兜底”的网站。双击单元格可编辑。")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 470
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemOrange
        statusLabel.preferredMaxLayoutWidth = 470

        let lookupLabel = NSTextField(labelWithString: "查词快捷键：")
        recorder.onRecord = { [weak self] shortcut in
            guard let self else { return }
            Preferences.lookupShortcut = shortcut
            self.lookupHotKey.register(shortcut)
            self.reload()
        }
        recorder.onRecordingChange = { [weak self] recording in
            if recording { self?.lookupHotKey.suspend() } else { self?.lookupHotKey.resume() }
        }
        lookupNote.font = .systemFont(ofSize: 11)
        let lookupHelp = NSTextField(wrappingLabelWithString: "在任何应用中选中字词后按此快捷键，在搜索窗口显示系统词典的释义；也可以直接输入 cd 仁。用的是“词典”App 中已启用的词典。读取选中文字需要“辅助功能”权限。")
        lookupHelp.font = .systemFont(ofSize: 11)
        lookupHelp.textColor = .secondaryLabelColor
        lookupHelp.preferredMaxLayoutWidth = 470

        let views: [NSView] = [scroll, add, remove, reset, help, statusLabel, lookupLabel, recorder, lookupNote, lookupHelp]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 190),
            add.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            add.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            remove.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            remove.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 6),
            reset.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            reset.leadingAnchor.constraint(equalTo: remove.trailingAnchor, constant: 6),
            help.topAnchor.constraint(equalTo: add.bottomAnchor, constant: 6),
            help.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            lookupLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            lookupLabel.centerYAnchor.constraint(equalTo: recorder.centerYAnchor),
            recorder.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            recorder.leadingAnchor.constraint(equalTo: lookupLabel.trailingAnchor, constant: 6),
            recorder.widthAnchor.constraint(equalToConstant: 150),
            lookupNote.leadingAnchor.constraint(equalTo: recorder.trailingAnchor, constant: 8),
            lookupNote.centerYAnchor.constraint(equalTo: recorder.centerYAnchor),
            lookupNote.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor),
            lookupHelp.topAnchor.constraint(equalTo: recorder.bottomAnchor, constant: 6),
            lookupHelp.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            lookupHelp.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            lookupHelp.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])
    }

    func reload() {
        if links != Preferences.quickLinks {
            links = Preferences.quickLinks
            table.reloadData()
        }
        recorder.shortcut = lookupHotKey.shortcut
        if let shortcut = lookupHotKey.shortcut, !lookupHotKey.isRegistered {
            lookupNote.stringValue = "\(shortcut.display) 已被占用（可能是 KongFetch），请换一个"
            lookupNote.textColor = .systemRed
        } else {
            lookupNote.stringValue = "⌫ 清除，⎋ 取消"
            lookupNote.textColor = .secondaryLabelColor
        }
        var problems: [String] = []
        let keywords = links.map { $0.keyword.lowercased() }.filter { !$0.isEmpty }
        let duplicates = Set(keywords.filter { k in keywords.filter { $0 == k }.count > 1 })
        if !duplicates.isEmpty { problems.append("关键词重复：" + duplicates.sorted().joined(separator: "、")) }
        let broken = links.filter { $0.url(for: "测试") == nil }.map { $0.name.isEmpty ? $0.keyword : $0.name }
        if !broken.isEmpty { problems.append("网址无效：" + broken.joined(separator: "、")) }
        if links.contains(where: { $0.keyword == DictionaryLookup.keyword }) { problems.append("“cd”已用于查词，同名关键词不会生效") }
        statusLabel.stringValue = problems.joined(separator: "；")
    }

    private func save() {
        Preferences.quickLinks = links
        reload()
    }

    @objc private func addLink() {
        links.append(QuickLink(keyword: "", name: "新网站", template: "https://"))
        save()
        table.reloadData()
        let row = links.count - 1
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        table.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func removeLink() {
        let row = table.selectedRow
        guard links.indices.contains(row) else { return }
        links.remove(at: row)
        save()
        table.reloadData()
    }

    @objc private func resetLinks() {
        Preferences.resetQuickLinks()
        links = []
        reload()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        links.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier.rawValue, let column = Column(rawValue: identifier) else { return nil }
        let link = links[row]
        if column == .fallback {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(fallbackToggled(_:)))
            checkbox.state = link.fallback ? .on : .off
            checkbox.tag = row
            return checkbox
        }
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier(column.rawValue)
        field.tag = row
        switch column {
        case .keyword: field.stringValue = link.keyword
        case .name: field.stringValue = link.name
        case .template: field.stringValue = link.template
        case .fallback: break
        }
        return field
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, links.indices.contains(field.tag),
              let column = field.identifier.flatMap({ Column(rawValue: $0.rawValue) }) else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        switch column {
        case .keyword: links[field.tag].keyword = value.replacingOccurrences(of: " ", with: "")
        case .name: links[field.tag].name = value
        case .template: links[field.tag].template = value
        case .fallback: break
        }
        save()
    }

    @objc private func fallbackToggled(_ sender: NSButton) {
        guard links.indices.contains(sender.tag) else { return }
        links[sender.tag].fallback = sender.state == .on
        save()
    }
}
