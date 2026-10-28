import AppKit
import ServiceManagement
import KongSeekCore

/// Settings pages "通用" (start at login, PDF reader, history, citation style, backup and
/// diagnostics, other apps) and "更新" (KongSeek and KongFolio updates); one class, so
/// they share their refresh code (0.26: split, the single page had grown too tall).
final class GeneralSettingsView: NSView {
    enum Page { case general, search, updates }

    private let page: Page
    private let updater: Updater
    private let library: SnippetLibrary
    private let diagnosticReport: () -> String

    private let versionLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceLabel = NSTextField(wrappingLabelWithString: "")
    private let autoCheckbox = NSButton(checkboxWithTitle: "自动检查更新（启动后，及每 6 小时）", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let proxyField = NSTextField()
    private let proxyNote = NSTextField(labelWithString: "")
    private let notesScroll = NSTextView.scrollableTextView()
    private var notesView: NSTextView { notesScroll.documentView as! NSTextView }
    private let checkButton = NSButton(title: "检查更新", target: nil, action: nil)
    private let installButton = NSButton(title: "安装更新", target: nil, action: nil)
    private let localButton = NSButton(title: "用本地源码重新构建", target: nil, action: nil)
    private let rollbackButton = NSButton(title: "回退到上一版…", target: nil, action: nil)
    private let logButton = NSButton(title: "更新日志", target: nil, action: nil)
    private let cliButton = NSButton(title: "安装命令行工具 ks…", target: nil, action: nil)
    private let cliLabel = NSTextField(labelWithString: "")
    private let claudeButton = NSButton(title: "添加到 Claude 桌面版…", target: nil, action: nil)
    private let claudeLabel = NSTextField(labelWithString: "")
    private let citationPopup = NSPopUpButton()
    /// PDF reading in KongFolio (0.25).
    private let readerPopup = NSPopUpButton()
    private let kongFolioButton = NSButton(title: "安装 KongFolio", target: nil, action: nil)
    private let kongFolioLabel = NSTextField(wrappingLabelWithString: "")
    private let historyCheckbox = NSButton(checkboxWithTitle: "记录搜索历史（在空搜索框中按 ↑ 查看）", target: nil, action: nil)
    private let copiesCheckbox = NSButton(checkboxWithTitle: "搜索结果中合并内容相同的副本", target: nil, action: nil)
    private let completionCheckbox = NSButton(checkboxWithTitle: "输入时自动补全（→ 接受）", target: nil, action: nil)
    private let bookTextCheckbox = NSButton(checkboxWithTitle: "为 EPUB、Kindle 电子书和 GB18030 文本建立正文索引", target: nil, action: nil)
    private let uncoveredCheckbox = NSButton(checkboxWithTitle: "也为 Spotlight 未收录的文件夹中的 PDF、Word、幻灯片建立正文索引", target: nil, action: nil)
    private let tipsCheckbox = NSButton(checkboxWithTitle: "搜索框为空时显示一条语法提示", target: nil, action: nil)
    /// What the text index holds, on the 搜索 page (0.42).
    private let bookTextStatus = NSTextField(wrappingLabelWithString: "")
    private let contentCheckbox = NSButton(checkboxWithTitle: "允许 Claude 按内容搜索并读取文件正文（只读，仅限已索引的文件夹）", target: nil, action: nil)

    private let loginCheckbox = NSButton(checkboxWithTitle: "开机登录后自动启动 KongSeek（在菜单栏待命）", target: nil, action: nil)
    private let loginNote = NSTextField(wrappingLabelWithString: "")
    private let loginSettingsButton = NSButton(title: "打开“登录项”设置…", target: nil, action: nil)

    init(page: Page, updater: Updater, library: SnippetLibrary, diagnosticReport: @escaping () -> String) {
        self.page = page
        self.updater = updater
        self.library = library
        self.diagnosticReport = diagnosticReport
        super.init(frame: .zero)
        build()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func build() {
        for label in [sourceLabel, statusLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        versionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        for label in [versionLabel, sourceLabel, statusLabel] { label.preferredMaxLayoutWidth = 520 }
        autoCheckbox.target = self
        autoCheckbox.action = #selector(autoChanged)
        notesView.isEditable = false
        notesView.font = .systemFont(ofSize: 12)
        notesView.textContainerInset = NSSize(width: 6, height: 6)
        notesScroll.hasVerticalScroller = true
        notesScroll.borderType = .bezelBorder

        let actions: [(NSButton, Selector)] = [
            (checkButton, #selector(checkNow)), (installButton, #selector(install)), (localButton, #selector(buildLocal)),
            (rollbackButton, #selector(rollback)), (logButton, #selector(showLog)),
        ]
        for (button, action) in actions {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        installButton.keyEquivalent = ""
        proxyField.placeholderString = "自动（使用系统代理）"
        proxyField.stringValue = Preferences.updateProxy
        proxyField.target = self
        proxyField.action = #selector(proxyChanged)
        proxyField.cell?.sendsActionOnEndEditing = true
        proxyField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        proxyNote.font = .systemFont(ofSize: 11)
        proxyNote.textColor = .secondaryLabelColor
        proxyNote.lineBreakMode = .byTruncatingTail
        let proxyRow = NSStackView(views: [NSTextField(labelWithString: "代理："), proxyField, proxyNote])
        proxyRow.spacing = 6
        let updateRow = NSStackView(views: [checkButton, installButton, localButton, rollbackButton, logButton])
        updateRow.spacing = 6

        let exportButton = NSButton(title: "导出设置…", target: self, action: #selector(exportSettings))
        let importButton = NSButton(title: "导入设置…", target: self, action: #selector(importSettings))
        let diagnosticsButton = NSButton(title: "导出诊断包…", target: self, action: #selector(exportDiagnostics))
        let transferRow = NSStackView(views: [exportButton, importButton, diagnosticsButton])
        transferRow.spacing = 6
        cliButton.target = self
        cliButton.action = #selector(installCommandLineTool)
        cliLabel.font = .systemFont(ofSize: 11)
        cliLabel.textColor = .secondaryLabelColor
        cliLabel.lineBreakMode = .byTruncatingMiddle
        let cliRow = NSStackView(views: [cliButton, cliLabel])
        cliRow.spacing = 8
        claudeButton.target = self
        claudeButton.action = #selector(addToClaude)
        claudeLabel.font = .systemFont(ofSize: 11)
        claudeLabel.textColor = .secondaryLabelColor
        claudeLabel.lineBreakMode = .byTruncatingTail
        let claudeRow = NSStackView(views: [claudeButton, claudeLabel])
        claudeRow.spacing = 8
        contentCheckbox.target = self
        contentCheckbox.action = #selector(contentChanged)
        historyCheckbox.target = self
        historyCheckbox.action = #selector(historyChanged)
        let clearHistory = NSButton(title: "清除搜索历史", target: self, action: #selector(clearHistory))
        clearHistory.controlSize = .small
        let aliasesButton = NSButton(title: "同义词与别名…", target: self, action: #selector(editAliases))
        aliasesButton.controlSize = .small
        aliasesButton.toolTip = "搜“阳明”也找到“王守仁”，搜“四书”也找到《论语》《孟子》等；文件名搜索和全文搜索都用"
        let historyRow = NSStackView(views: [historyCheckbox, clearHistory])
        historyRow.spacing = 10
        copiesCheckbox.target = self
        copiesCheckbox.action = #selector(copiesChanged)
        copiesCheckbox.toolTip = "内容完全相同的几个文件只列一行，注明“另有 N 个副本”，⌘K 可看各副本的位置"
        let filterButton = NSButton(title: "筛选按钮…", target: self, action: #selector(editFilterButtons))
        filterButton.controlSize = .small
        filterButton.toolTip = "搜索框下的按钮，如 PDF = ext:pdf；点一下加入搜索，再点去掉"
        completionCheckbox.target = self
        completionCheckbox.action = #selector(completionChanged)
        completionCheckbox.toolTip = "按搜索历史、收藏的搜索和最近打开的文件名，在输入框中以选中的灰色文字给出补全；继续输入即替换，按 → 接受"
        let toolsRow = NSStackView(views: [aliasesButton, filterButton])
        toolsRow.spacing = 10
        tipsCheckbox.target = self
        tipsCheckbox.action = #selector(tipsChanged)
        bookTextStatus.font = .systemFont(ofSize: 11)
        bookTextStatus.textColor = .secondaryLabelColor
        bookTextStatus.preferredMaxLayoutWidth = 520
        /// A line of explanation under an option (0.42).
        func note(_ text: String) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 520
            return label
        }
        let historyNote = note("打开或显示过结果的搜索会记下（最多 50 条）；搜索框为空时按 ↑ 查看。")
        let completionNote = note("按搜索历史、收藏的搜索和最近打开的文件名补全；补上的部分以选中的文字显示，继续输入即替换，按 → 接受。")
        let copiesNote = note("内容完全相同的几个文件只列一行，注明“另有 N 个副本”，⌘K 可看各副本的位置。")
        let tipsNote = note("轮流显示一条搜索语法（如 作者:、备注:、near:、/文件夹），↩ 填入示例。")
        let toolsNote = note("同义词：搜“阳明”也找到“王守仁”，搜“四书”也找到《论语》等。筛选按钮：搜索框下的 PDF、Word 等按钮，可改成自己的。")
        let bookTextNote = note("Spotlight 读不到正文的 EPUB、Kindle 电子书和 GB18030 文本，KongSeek 在后台自己读出文字；只读本机已下载的文件。")
        bookTextCheckbox.target = self
        bookTextCheckbox.action = #selector(bookTextChanged)
        uncoveredCheckbox.target = self
        uncoveredCheckbox.action = #selector(bookTextChanged)
        uncoveredCheckbox.toolTip = "Spotlight 不收录的文件夹（在“系统设置 › Spotlight”中排除的、关闭了索引的磁盘上的）里的文件，全文搜不到；KongSeek 每天检查一次，由它自己读取这些文件的正文"
        bookTextCheckbox.toolTip = "Spotlight 读不到这些文件的正文；KongSeek 在后台读取（只读本机已下载的文件），全文搜索、引文查证、出处汇编就能找到它们"
        for style in Citation.Style.allCases { citationPopup.addItem(withTitle: style.title) }
        citationPopup.target = self
        citationPopup.action = #selector(citationChanged)
        let equivalentsButton = NSButton(title: "通假与古今字表…", target: self, action: #selector(editEquivalents))
        equivalentsButton.controlSize = .small
        equivalentsButton.toolTip = "逐字异文中，表里的字对（如 说=悦）标为“通假”，不算错字"
        let citationRow = NSStackView(views: [NSTextField(labelWithString: "参考文献与引文格式："), citationPopup, equivalentsButton])
        citationRow.spacing = 6
        for reader in Preferences.PDFReader.allCases { readerPopup.addItem(withTitle: reader.title) }
        readerPopup.target = self
        readerPopup.action = #selector(readerChanged)
        readerPopup.toolTip = "搜索窗口中 ⌥↩、引文查证与稿件核对的“打开到此处”、菜单栏“最近阅读”打开 PDF 的地方"
        let readerRow = NSStackView(views: [NSTextField(labelWithString: "按页打开 PDF 用："), readerPopup])
        readerRow.spacing = 6
        kongFolioButton.target = self
        kongFolioButton.action = #selector(installKongFolio)
        kongFolioButton.bezelStyle = .rounded
        kongFolioLabel.font = .systemFont(ofSize: 11)
        kongFolioLabel.textColor = .secondaryLabelColor
        kongFolioLabel.preferredMaxLayoutWidth = 380
        let kongFolioRow = NSStackView(views: [kongFolioButton, kongFolioLabel])
        kongFolioRow.spacing = 8
        kongFolioRow.alignment = .centerY
        contentCheckbox.toolTip = "关闭后，Claude 只能按文件名搜索（search_files），不能搜索正文（search_content）或读取文件（read_file）。"
        let transferHelp = NSTextField(wrappingLabelWithString: "设置文件包含各页的设置、文本片段，以及书上页码、补全的书目、常用本、文件清单、阅读进度（0.29 起），不含剪贴板历史、最近打开和索引，可用于换机或备份；主目录下的路径会自动换成新电脑的主目录。诊断包含状态报告、更新与构建日志、最近的崩溃报告和设置（不含片段与剪贴板内容），出问题时发给开发者。")
        transferHelp.font = .systemFont(ofSize: 11)
        transferHelp.textColor = .secondaryLabelColor
        transferHelp.preferredMaxLayoutWidth = 520

        func heading(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            return label
        }
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged)
        loginNote.font = .systemFont(ofSize: 11)
        loginNote.textColor = .secondaryLabelColor
        loginNote.preferredMaxLayoutWidth = 520
        loginSettingsButton.target = self
        loginSettingsButton.action = #selector(openLoginItems)
        loginSettingsButton.controlSize = .small

        let views: [NSView]
        switch page {
        case .general:
            views = [heading("启动"), loginCheckbox, loginNote, loginSettingsButton,
                     heading("PDF 阅读"), readerRow,
                     heading("引文"), citationRow,
                     heading("备份与诊断"), transferRow, transferHelp,
                     heading("其他应用"), cliRow, claudeRow, contentCheckbox]
        case .search:
            // 搜索 (0.42): the options that change how searching works, each with a line saying what it does.
            views = [heading("输入与结果"), historyRow, historyNote, completionCheckbox, completionNote, copiesCheckbox, copiesNote, tipsCheckbox, tipsNote,
                     heading("同义词与筛选按钮"), toolsRow, toolsNote,
                     heading("正文索引"), bookTextCheckbox, uncoveredCheckbox, bookTextNote, bookTextStatus]
        case .updates:
            views = [versionLabel, sourceLabel,
                     heading("更新 KongSeek"), autoCheckbox, proxyRow, statusLabel, notesScroll, updateRow,
                     heading("KongFolio（PDF 阅读与批注）"), kongFolioRow]
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        // More room before each heading.
        let sectionEnds: [NSView] = [sourceLabel, updateRow, loginNote, loginSettingsButton, readerRow, citationRow, transferHelp, tipsNote, toolsNote]
        for view in sectionEnds where views.contains(where: { $0 === view }) {
            stack.setCustomSpacing(14, after: view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints = [
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ]
        switch page {
        case .general:
            constraints += [transferHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
                            loginNote.widthAnchor.constraint(equalTo: stack.widthAnchor)]
        case .search:
            constraints += [bookTextStatus.widthAnchor.constraint(equalTo: stack.widthAnchor)]
        case .updates:
            constraints += [notesScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                            notesScroll.heightAnchor.constraint(equalToConstant: 110),
                            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)]
        }
        NSLayoutConstraint.activate(constraints)
    }

    func refresh() {
        let state = updater.state
        var version = "KongSeek \(Updater.version)（构建 \(Updater.build)"
        if let commit = Updater.installedCommit { version += " · \(commit.prefix(7))" }
        versionLabel.stringValue = version + "）"
        sourceLabel.stringValue = "签名：\(Updater.signingDescription())\n源码文件夹："
            + (state.sourceRoot.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "未找到（应在 ~/Developer/kongseek）")
        autoCheckbox.state = Preferences.autoCheckUpdates ? .on : .off
        let typed = Preferences.updateProxy.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            proxyNote.stringValue = "系统代理：" + (Updater.systemProxy ?? "无（直连）")
            proxyNote.textColor = .secondaryLabelColor
        } else if ProxySettings.normalized(typed) == nil {
            proxyNote.stringValue = "格式不对，例：127.0.0.1:7890"
            proxyNote.textColor = .systemRed
        } else {
            proxyNote.stringValue = "如 Clash 默认 127.0.0.1:7890"
            proxyNote.textColor = .secondaryLabelColor
        }

        var status: String
        switch state.phase {
        case .checking: status = "正在检查 GitHub…"
        case .updating(let step): status = step
        case .failed(let message): status = "⚠︎ " + message
        case .idle:
            if let remote = state.remoteVersion {
                status = "有新版本 \(remote)。点“安装更新”会在本机测试、编译并安装（约一两分钟），之后 KongSeek 自动重新打开。"
            } else if !state.pending.isEmpty {
                status = "GitHub 上有 \(state.pending.count) 个新提交。"
            } else if state.lastCheck != nil {
                status = "已是最新版本。"
            } else {
                status = "尚未检查。"
            }
        }
        if let check = state.lastCheck { status += "  上次检查：\(check.formatted(date: .omitted, time: .shortened))" }
        statusLabel.stringValue = status

        let notes: String
        if !state.notes.isEmpty {
            notes = state.notes.map { "\($0.version)\n\($0.body)" }.joined(separator: "\n\n")
        } else if !state.pending.isEmpty {
            notes = state.pending.map { "• " + $0 }.joined(separator: "\n")
        } else {
            notes = "有新版本时，这里显示更新内容。"
        }
        if notesView.string != notes { notesView.string = notes }

        let busy = state.isBusy
        let hasSource = state.sourceRoot != nil
        checkButton.isEnabled = !busy && hasSource
        installButton.isEnabled = !busy && hasSource && state.hasUpdate
        localButton.isEnabled = !busy && hasSource
        rollbackButton.isEnabled = !busy && !state.backups.isEmpty
        rollbackButton.toolTip = state.backups.first.map { "回退到 " + $0.replacingOccurrences(of: ".app", with: "") }
        logButton.isEnabled = FileManager.default.fileExists(atPath: updater.logURL.path)
        cliLabel.stringValue = CommandLineTool.status
        claudeLabel.stringValue = ClaudeDesktop.status
        contentCheckbox.state = Preferences.mcpReadContent ? .on : .off
        historyCheckbox.state = Preferences.keepSearchHistory ? .on : .off
        copiesCheckbox.state = Preferences.mergeCopies ? .on : .off
        completionCheckbox.state = Preferences.autocomplete ? .on : .off
        tipsCheckbox.state = Preferences.showTips ? .on : .off
        let books = BookTextService.shared
        let summary = books.index.summary
        var bookText = Preferences.bookTextIndex ? "已收录 \(summary.books) 本（约 \(max(1, summary.characters / 10_000)) 万字）" : "已关闭"
        if Preferences.bookTextIndex && summary.problems > 0 { bookText += "；\(summary.problems) 本读不出文字" }
        if books.uncoveredFolderCount > 0 { bookText += "；含 Spotlight 未收录的 \(books.uncoveredFolderCount) 个文件夹" }
        if books.running { bookText += "；正在读取 \(books.progress.done) / \(books.progress.total)" }
        if bookTextStatus.stringValue != bookText { bookTextStatus.stringValue = bookText }
        bookTextCheckbox.state = Preferences.bookTextIndex ? .on : .off
        uncoveredCheckbox.state = Preferences.indexUncoveredFolders ? .on : .off
        uncoveredCheckbox.isEnabled = Preferences.bookTextIndex
        citationPopup.selectItem(at: Citation.Style.allCases.firstIndex(of: Preferences.citationStyle) ?? 0)
        refreshKongFolio()
        refreshLogin()
    }

    /// Start at login (SMAppService; 0.26 moved here from 索引 and explains the states).
    private func refreshLogin() {
        let status = SMAppService.mainApp.status
        loginCheckbox.state = status == .enabled || status == .requiresApproval ? .on : .off
        loginSettingsButton.isHidden = status != .requiresApproval
        switch status {
        case .enabled:
            loginNote.stringValue = "已开启：每次开机登录后，KongSeek 自动在菜单栏出现，⌥空格随时可用。也可在 系统设置 › 通用 › 登录项 中看到。"
        case .requiresApproval:
            loginNote.stringValue = "还差一步：macOS 要你在 系统设置 › 通用 › 登录项 中允许 KongSeek（打开“允许在后台”或把它加入“登录时打开”）。"
        case .notFound:
            loginNote.stringValue = "KongSeek 不在“应用程序”文件夹时无法设为开机启动。"
        default:
            loginNote.stringValue = "关闭：开机后需要自己打开 KongSeek。"
        }
    }

    @objc private func loginChanged() {
        do {
            if loginCheckbox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法更改开机启动设置"
            alert.informativeText = error.localizedDescription + (SMAppService.mainApp.status == .requiresApproval ? "\n\n请在 系统设置 › 通用 › 登录项 中允许 KongSeek。" : "")
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
        refresh()
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func refreshKongFolio() {
        readerPopup.selectItem(at: Preferences.PDFReader.allCases.firstIndex(of: Preferences.pdfReader) ?? 0)
        let installer = KongFolioInstaller.shared
        let installed = KongFolio.installedVersion
        kongFolioButton.title = installed == nil ? "安装 KongFolio" : "更新 KongFolio"
        kongFolioButton.isEnabled = !installer.isBusy && !updater.state.isBusy
        var text: String
        switch installer.phase {
        case .working(let step): text = step
        case .failed(let message): text = "⚠︎ " + message
        case .done(let message): text = message + "。"
        case .idle:
            if let installed {
                text = "已安装 KongFolio \(installed)。" + (KongFolio.isReader ? "PDF 在 KongFolio 中打开到命中页，标记保留在页面上。" : "")
                if let source = KongFolioInstaller.sourceVersion, source != installed { text += "源码中的版本是 \(source)。" }
                text += "点“更新”从 GitHub 获取最新版，在本机编译后替换（需 KongFolio 0.34 起才保留标记、接着上次读）。"
            } else {
                text = "没有找到 KongFolio。点“安装”从 GitHub 下载源码到 ~/Developer/kongfolio，在本机编译后放进“应用程序”（第一次约需 5–10 分钟）。"
            }
        }
        if kongFolioLabel.stringValue != text { kongFolioLabel.stringValue = text }
    }

    @objc private func bookTextChanged() {
        Preferences.bookTextIndex = bookTextCheckbox.state == .on
        Preferences.indexUncoveredFolders = uncoveredCheckbox.state == .on
        uncoveredCheckbox.isEnabled = Preferences.bookTextIndex
        NotificationCenter.default.post(name: BookTextService.settingChanged, object: nil)
    }

    @objc private func tipsChanged() {
        Preferences.showTips = tipsCheckbox.state == .on
    }

    @objc private func completionChanged() {
        Preferences.autocomplete = completionCheckbox.state == .on
    }

    @objc private func copiesChanged() {
        Preferences.mergeCopies = copiesCheckbox.state == .on
    }

    /// 筛选按钮 (0.36): one button per line, "名称=搜索语法".
    @objc private func editFilterButtons() {
        let alert = NSAlert()
        alert.messageText = "搜索框下的筛选按钮"
        alert.informativeText = "每行一个按钮：“名称=加入搜索的内容”，如“PDF=ext:pdf”“书库=in:电子书”“本学期讲义=in:论语 dm:thisyear”。"
            + "点按钮把内容加入搜索框，再点一次去掉；可以同时按下几个。"
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 380, height: 200)
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.font = .systemFont(ofSize: 13)
        text.isRichText = false
        text.string = Preferences.filterButtonLines.joined(separator: "\n")
        let show = NSButton(checkboxWithTitle: "在搜索框下显示筛选按钮", target: nil, action: nil)
        show.state = Preferences.showFilterButtons ? .on : .off
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalToConstant: 380), scroll.heightAnchor.constraint(equalToConstant: 200)])
        let stack = NSStackView(views: [scroll, show])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 228)
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "恢复默认按钮")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let lines = text.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            Preferences.filterButtonLines = FilterFragments(lines: lines).lines
            Preferences.showFilterButtons = show.state == .on
        case .alertThirdButtonReturn:
            Preferences.filterButtonLines = FilterFragments.standardLines
            Preferences.showFilterButtons = true
        default:
            break
        }
    }

    /// 同义词与别名 (0.35): one group per line, "王守仁=王阳明=阳明", or "四书>论语,孟子,大学,中庸".
    @objc private func editAliases() {
        let alert = NSAlert()
        alert.messageText = "同义词与别名"
        alert.informativeText = "每行一组。“王守仁=王阳明=阳明”：搜其中任一个，文件名或正文中有其他几个的也找到。"
            + "“四书>论语,孟子,大学,中庸”：搜“四书”也找到后面几种，反过来不算。繁简不必分写；全拼也可（yangming 即 阳明）。"
            + "这些名称排在按原词找到的文件之后。"
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 280)
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.font = .systemFont(ofSize: 13)
        text.isRichText = false
        text.string = Preferences.searchAliasLines.joined(separator: "\n")
        alert.accessoryView = scroll
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "恢复常用表")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let lines = text.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            Preferences.searchAliasLines = SearchAliases(lines: lines).lines
        case .alertThirdButtonReturn:
            Preferences.searchAliasLines = SearchAliases.standardLines
        default:
            break
        }
    }

    /// 通假与古今字表 (0.29): one pair per line, "说=悦".
    @objc private func editEquivalents() {
        let alert = NSAlert()
        alert.messageText = "通假与古今字表"
        alert.informativeText = "每行一对，如“说=悦”“莫=暮”。引文与原文只差在这些字上时，逐字异文标为“通假”，不算错字，也不加批注。繁简不必分写。"
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.font = .systemFont(ofSize: 13)
        text.isRichText = false
        text.string = Preferences.quoteEquivalentLines.joined(separator: "\n")
        alert.accessoryView = scroll
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "恢复常见字例")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let lines = text.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            Preferences.quoteEquivalentLines = CharacterEquivalents(lines: lines).lines
        case .alertThirdButtonReturn:
            Preferences.quoteEquivalentLines = CharacterEquivalents.standardLines
        default:
            break
        }
    }

    @objc private func readerChanged() {
        let all = Preferences.PDFReader.allCases
        Preferences.pdfReader = all[max(0, min(readerPopup.indexOfSelectedItem, all.count - 1))]
        refresh()
    }

    @objc private func installKongFolio() {
        let installer = KongFolioInstaller.shared
        if NSRunningApplication.runningApplications(withBundleIdentifier: KongFolioLink.bundleIdentifier).isEmpty == false {
            let alert = NSAlert()
            alert.messageText = "安装时需要退出 KongFolio"
            alert.informativeText = "编译完成后会请 KongFolio 退出（有未保存的修改时它会询问），装好后自动重新打开。"
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        installer.install()
        refresh()
    }

    // MARK: Actions

    @objc private func autoChanged() {
        Preferences.autoCheckUpdates = autoCheckbox.state == .on
        if Preferences.autoCheckUpdates { updater.startAutomaticChecks() } else { updater.stopAutomaticChecks() }
    }

    @objc private func proxyChanged() {
        Preferences.updateProxy = proxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        refresh()
    }

    @objc private func checkNow() {
        updater.clearFailure()
        updater.check()
        refresh()
    }

    @objc private func install() {
        updater.clearFailure()
        updater.update()
        refresh()
    }

    @objc private func buildLocal() {
        let alert = NSAlert()
        alert.messageText = "用源码文件夹中的代码重新构建？"
        alert.informativeText = "不连 GitHub，直接用 \((updater.state.sourceRoot ?? "") as NSString) 中现有的代码测试、编译并安装（约一两分钟），之后 KongSeek 自动重新打开。"
        alert.addButton(withTitle: "构建")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updater.clearFailure()
        updater.update(fromLocalSource: true)
        refresh()
    }

    @objc private func rollback() {
        guard let latest = updater.state.backups.first else { return }
        let alert = NSAlert()
        alert.messageText = "回退到 \(latest.replacingOccurrences(of: ".app", with: ""))？"
        alert.informativeText = "KongSeek 会退出并打开上一版。设置和数据不受影响。"
        alert.addButton(withTitle: "回退")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { updater.rollback() }
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(updater.logURL)
    }

    @objc private func installCommandLineTool() {
        let alert = NSAlert()
        alert.messageText = "安装命令行工具 ks？"
        alert.informativeText = "在 /usr/local/bin 中建立指向 KongSeek 内置 ks 的链接，之后可在“终端”中输入 ks 合同 搜索（ks --help 查看用法）。若该文件夹需要管理员权限，macOS 会请你输入密码。"
        alert.addButton(withTitle: "安装")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let message = CommandLineTool.install()
        let done = NSAlert()
        done.messageText = message
        done.runModal()
        refresh()
    }

    @objc private func historyChanged() {
        Preferences.keepSearchHistory = historyCheckbox.state == .on
    }

    @objc private func citationChanged() {
        let styles = Citation.Style.allCases
        let index = citationPopup.indexOfSelectedItem
        if styles.indices.contains(index) { Preferences.citationStyle = styles[index] }
    }

    @objc private func clearHistory() {
        Preferences.searchHistory = []
    }

    @objc private func contentChanged() {
        Preferences.mcpReadContent = contentCheckbox.state == .on
    }

    @objc private func addToClaude() {
        let alert = NSAlert()
        alert.messageText = "让 Claude 桌面版可以用 KongSeek 搜索文件？"
        alert.informativeText = "在 Claude 的配置文件（~/Library/Application Support/Claude/claude_desktop_config.json）中加入 KongSeek 的 MCP 服务，原文件先备份。之后 Claude 能按文件名（含拼音）和正文内容搜索你已索引的文件，并读取文件正文（只读，不修改任何文件；正文读取可在本页关闭）。\n\n完成后请退出并重新打开 Claude 桌面版。"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let done = NSAlert()
        do {
            try ClaudeDesktop.add()
            done.messageText = "已添加。请退出并重新打开 Claude 桌面版。"
            done.informativeText = "在 Claude 中可以直接说“用 KongSeek 找一下论语讲义的 PDF”。"
        } catch {
            done.messageText = "没能添加：\(error.localizedDescription)"
        }
        done.runModal()
        refresh()
    }

    @objc private func exportSettings() {
        SettingsTransfer.exportSettings(library: library)
    }

    @objc private func importSettings() {
        SettingsTransfer.importSettings(library: library)
    }

    @objc private func exportDiagnostics() {
        DiagnosticsBundle.export(report: diagnosticReport(), updateLog: updater.logURL, sourceRoot: updater.state.sourceRoot)
    }
}

/// The ks command (Contents/MacOS/ks) linked into /usr/local/bin.
enum CommandLineTool {
    static let linkPath = "/usr/local/bin/ks"
    static var bundled: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ks").path }

    static var status: String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundled) else { return "此版本未包含 ks" }
        if let target = try? fm.destinationOfSymbolicLink(atPath: linkPath) {
            return target == bundled ? "已安装：在“终端”中输入 ks --help" : "/usr/local/bin/ks 指向别处：\(target)"
        }
        return fm.fileExists(atPath: linkPath) ? "/usr/local/bin/ks 已被其他文件占用" : "未安装"
    }

    /// Links ks into /usr/local/bin, asking for an administrator password when needed.
    static func install() -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundled) else { return "此版本未包含 ks，请先更新 KongSeek。" }
        if fm.fileExists(atPath: linkPath), (try? fm.destinationOfSymbolicLink(atPath: linkPath)) == nil {
            return "/usr/local/bin/ks 是一个普通文件，为免覆盖，没有安装。"
        }
        let folder = (linkPath as NSString).deletingLastPathComponent
        if fm.isWritableFile(atPath: folder) {
            do {
                if (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil { try fm.removeItem(atPath: linkPath) }
                try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: bundled)
                return "已安装 ks。在“终端”中输入 ks --help 查看用法。"
            } catch {
                return "安装失败：\(error.localizedDescription)"
            }
        }
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "mkdir -p \(quoted(folder)) && ln -sfh \(quoted(bundled)) \(quoted(linkPath))"
        let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        _ = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            return code == -128 ? "已取消。" : "安装失败：\(error[NSAppleScript.errorMessage] as? String ?? "未知错误")"
        }
        return "已安装 ks。在“终端”中输入 ks --help 查看用法。"
    }
}

/// Registers `ks mcp` as an MCP server in the Claude desktop app's configuration.
enum ClaudeDesktop {
    static let serverName = "kongseek"
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    enum ConfigError: LocalizedError {
        case unreadable, noTool
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Claude 的配置文件不是有效的 JSON，为免损坏，没有修改。"
            case .noTool: return "此版本未包含 ks，请先更新 KongSeek。"
            }
        }
    }

    private static func readConfig() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL), !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConfigError.unreadable }
        return object
    }

    static var status: String {
        guard FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path) else { return "未发现 Claude 桌面版" }
        guard let config = try? readConfig() else { return "Claude 配置文件无法读取" }
        let entry = (config["mcpServers"] as? [String: Any])?[serverName] as? [String: Any]
        guard let command = entry?["command"] as? String else { return "未添加" }
        return command == CommandLineTool.bundled ? "已添加（重新打开 Claude 后生效）" : "已添加，但指向 \(command)"
    }

    static func add() throws {
        guard FileManager.default.fileExists(atPath: CommandLineTool.bundled) else { throw ConfigError.noTool }
        var config: [String: Any]
        do { config = try readConfig() } catch { throw ConfigError.unreadable }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": CommandLineTool.bundled, "args": ["mcp"]] as [String: Any]
        config["mcpServers"] = servers
        let fm = FileManager.default
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: configURL.path) {
            let backup = configURL.appendingPathExtension("kongseek-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: configURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: configURL, options: .atomic)
    }
}
