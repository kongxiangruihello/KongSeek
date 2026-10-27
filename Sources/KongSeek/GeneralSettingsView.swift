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
    private let notesScroll = NSTextView.scrollableTextView()
    private var notesView: NSTextView { notesScroll.documentView as! NSTextView }
    private let checkButton = NSButton(title: "检查更新", target: nil, action: nil)
    private let installButton = NSButton(title: "安装更新", target: nil, action: nil)
    private let localButton = NSButton(title: "用本地源码重新构建", target: nil, action: nil)
    private let rollbackButton = NSButton(title: "回退到上一版…", target: nil, action: nil)
    private let logButton = NSButton(title: "更新日志", target: nil, action: nil)

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
        let updateRow = NSStackView(views: [checkButton, installButton, localButton, rollbackButton, logButton])
        updateRow.spacing = 6

        let exportButton = NSButton(title: "导出设置…", target: self, action: #selector(exportSettings))
        let importButton = NSButton(title: "导入设置…", target: self, action: #selector(importSettings))
        let diagnosticsButton = NSButton(title: "导出诊断包…", target: self, action: #selector(exportDiagnostics))
        let transferRow = NSStackView(views: [exportButton, importButton, diagnosticsButton])
        transferRow.spacing = 6
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
            heading("更新"), autoCheckbox, statusLabel, notesScroll, updateRow,
            heading("设置与诊断"), transferRow, transferHelp,
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
            notesScroll.heightAnchor.constraint(equalToConstant: 120),
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
    }

    // MARK: Actions

    @objc private func autoChanged() {
        Preferences.autoCheckUpdates = autoCheckbox.state == .on
        if Preferences.autoCheckUpdates { updater.startAutomaticChecks() } else { updater.stopAutomaticChecks() }
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
