import AppKit
import KongSeekCore

/// Shows an update step by step: a progress bar, the steps with ✓ / ● / ✕,
/// what is happening right now ("测试：已通过 52 / 117 项"), the time taken, and
/// on failure what went wrong, that nothing was changed, and where the log is.
final class UpdateProgressWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let updater: Updater
    private let titleLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let percentLabel = NSTextField(labelWithString: "")
    private let stepsStack = NSStackView()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let logButton = NSButton(title: "查看构建日志", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private var timer: Timer?
    private var stepRows: [Updater.Step: (icon: NSTextField, label: NSTextField)] = [:]

    init(updater: Updater) {
        self.updater = updater
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        window.title = "KongSeek 更新"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        build()
    }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percentLabel.textColor = .secondaryLabelColor
        let barRow = NSStackView(views: [bar, percentLabel])
        barRow.spacing = 8
        stepsStack.orientation = .vertical
        stepsStack.alignment = .leading
        stepsStack.spacing = 5
        for step in Updater.Step.allCases {
            let icon = NSTextField(labelWithString: "")
            icon.font = .systemFont(ofSize: 13, weight: .bold)
            icon.alignment = .center
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let label = NSTextField(labelWithString: step.title)
            label.font = .systemFont(ofSize: 13)
            let row = NSStackView(views: [icon, label])
            row.spacing = 6
            stepsStack.addArrangedSubview(row)
            stepRows[step] = (icon, label)
        }
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12)
        logButton.target = self
        logButton.action = #selector(openLog)
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [logButton, closeButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [titleLabel, barRow, stepsStack, detailLabel, messageLabel, timeLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: barRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            barRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            percentLabel.widthAnchor.constraint(equalToConstant: 40),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    func show() {
        refresh()
        if !window.isVisible { window.placeRemembered() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        // Keeps the elapsed time moving between build messages.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard let progress = updater.state.progress else { return }
        titleLabel.stringValue = progress.title
        bar.doubleValue = progress.fraction
        percentLabel.stringValue = "\(Int((progress.fraction * 100).rounded()))%"
        let failed = progress.failure != nil
        let currentIndex = Updater.Step.allCases.firstIndex(of: progress.current) ?? 0
        for step in Updater.Step.allCases {
            guard let row = stepRows[step] else { continue }
            let included = progress.steps.contains(step)
            row.icon.superview?.isHidden = !included
            let index = Updater.Step.allCases.firstIndex(of: step) ?? 0
            if index < currentIndex || (progress.finished && index <= currentIndex) {
                row.icon.stringValue = "✓"
                row.icon.textColor = .systemGreen
                row.label.textColor = .labelColor
            } else if index == currentIndex {
                row.icon.stringValue = failed ? "✕" : "●"
                row.icon.textColor = failed ? .systemRed : .controlAccentColor
                row.label.textColor = .labelColor
            } else {
                row.icon.stringValue = "○"
                row.icon.textColor = .tertiaryLabelColor
                row.label.textColor = .secondaryLabelColor
            }
        }
        detailLabel.stringValue = failed ? "" : progress.detail
        detailLabel.isHidden = failed
        if let failure = progress.failure {
            messageLabel.stringValue = "⚠︎ " + failure
            messageLabel.textColor = .systemRed
            messageLabel.isHidden = false
        } else if progress.finished {
            messageLabel.stringValue = "更新成功。KongSeek 会自动退出并重新打开，无需任何操作。"
            messageLabel.textColor = .systemGreen
            messageLabel.isHidden = false
        } else {
            messageLabel.stringValue = "通常需要一两分钟。可以关闭此窗口，更新会在后台继续；完成后 KongSeek 自动重新打开。"
            messageLabel.textColor = .secondaryLabelColor
            messageLabel.isHidden = false
        }
        let elapsed = Int(Date().timeIntervalSince(progress.started))
        timeLabel.stringValue = (failed || progress.finished ? "用时 " : "已用 ") + String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        if failed || progress.finished { timer?.invalidate() }
        logButton.isHidden = !failed
        closeButton.title = failed || progress.finished ? "关闭" : "在后台继续"
        bar.isHidden = failed
        percentLabel.isHidden = failed
    }

    @objc private func openLog() {
        if let root = updater.state.sourceRoot {
            let buildLog = URL(fileURLWithPath: root).appendingPathComponent("build/build.log")
            if FileManager.default.fileExists(atPath: buildLog.path) {
                NSWorkspace.shared.open(buildLog)
                return
            }
        }
        NSWorkspace.shared.open(updater.logURL)
    }

    @objc private func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        if updater.state.progress?.failure != nil { updater.dismissProgress() }
    }
}
