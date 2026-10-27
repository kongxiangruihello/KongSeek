import AppKit
import KongSeekCore

/// Settings page "通用": version, updates, settings export/import and diagnostics.
final class GeneralSettingsView: NSView {
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
    private let historyCheckbox = NSButton(checkboxWithTitle: "记录搜索历史（在空搜索框中按 ↑ 查看）", target: nil, action: nil)
    private let contentCheckbox = NSButton(checkboxWithTitle: "允许 Claude 按内容搜索并读取文件正文（只读，仅限已索引的文件夹）", target: nil, action: nil)

    init(updater: Updater, library: SnippetLibrary, diagnosticReport: @escaping () -> String) {
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
        let historyRow = NSStackView(views: [historyCheckbox, clearHistory])
        historyRow.spacing = 10
        contentCheckbox.toolTip = "关闭后，Claude 只能按文件名搜索（search_files），不能搜索正文（search_content）或读取文件（read_file）。"
        let transferHelp = NSTextField(wrappingLabelWithString: "设置文件包含各页的设置和文本片段，不含剪贴板历史、最近打开和索引，可用于换机或备份；主目录下的路径会自动换成新电脑的主目录。诊断包含状态报告、更新与构建日志、最近的崩溃报告和设置（不含片段与剪贴板内容），出问题时发给开发者。")
        transferHelp.font = .systemFont(ofSize: 11)
        transferHelp.textColor = .secondaryLabelColor
        transferHelp.preferredMaxLayoutWidth = 520

        func heading(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            return label
        }
        let stack = NSStackView(views: [
            versionLabel, sourceLabel,
            heading("更新"), autoCheckbox, proxyRow, statusLabel, notesScroll, updateRow,
            heading("设置与诊断"), historyRow, transferRow, transferHelp, cliRow, claudeRow, contentCheckbox,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(14, after: sourceLabel)
        stack.setCustomSpacing(14, after: updateRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            notesScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notesScroll.heightAnchor.constraint(equalToConstant: 80),
            transferHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
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
