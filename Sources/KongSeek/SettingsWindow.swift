import AppKit
import KongSeekCore

/// Settings for how the search window is opened: the shortcut and the double tap.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let hotKey: HotKey
    private let doubleTap: DoubleTapMonitor
    private let onChange: () -> Void

    private let recorder = ShortcutRecorderButton()
    private let shortcutNote = NSTextField(wrappingLabelWithString: "")
    private let tapPopup = NSPopUpButton()
    private let tapNote = NSTextField(wrappingLabelWithString: "")
    private let permissionButton = NSButton(title: "授予“输入监控”权限…", target: nil, action: nil)
    private var refreshTimer: Timer?

    init(hotKey: HotKey, doubleTap: DoubleTapMonitor, onChange: @escaping () -> Void) {
        self.hotKey = hotKey
        self.doubleTap = doubleTap
        self.onChange = onChange
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 250), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        window.title = "KongSeek 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildLayout()
    }

    func show() {
        refresh()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refreshTimer?.invalidate()
        // Picks up a permission granted in System Settings while this window is open.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        recorder.stopRecording()
    }

    private func buildLayout() {
        let content = NSView()
        window.contentView = content

        let shortcutLabel = NSTextField(labelWithString: "唤起快捷键：")
        recorder.onRecord = { [weak self] shortcut in self?.apply(shortcut) }
        recorder.onRecordingChange = { [weak self] recording in
            if recording { self?.hotKey.suspend() } else { self?.hotKey.resume() }
        }
        let resetButton = NSButton(title: "恢复 ⌥空格", target: self, action: #selector(resetShortcut))
        resetButton.bezelStyle = .rounded

        let tapLabel = NSTextField(labelWithString: "连按两次唤起：")
        for modifier in TapModifier.allCases {
            tapPopup.addItem(withTitle: modifier.title)
            tapPopup.lastItem?.representedObject = modifier.rawValue
        }
        tapPopup.target = self
        tapPopup.action = #selector(tapChanged)
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        permissionButton.bezelStyle = .rounded

        for note in [shortcutNote, tapNote] {
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = 300
        }

        for view in [shortcutLabel, recorder, resetButton, shortcutNote, tapLabel, tapPopup, tapNote, permissionButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            shortcutLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            shortcutLabel.widthAnchor.constraint(equalToConstant: 110),
            shortcutLabel.centerYAnchor.constraint(equalTo: recorder.centerYAnchor),
            recorder.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            recorder.leadingAnchor.constraint(equalTo: shortcutLabel.trailingAnchor, constant: 8),
            recorder.widthAnchor.constraint(equalToConstant: 170),
            resetButton.leadingAnchor.constraint(equalTo: recorder.trailingAnchor, constant: 8),
            resetButton.centerYAnchor.constraint(equalTo: recorder.centerYAnchor),
            shortcutNote.topAnchor.constraint(equalTo: recorder.bottomAnchor, constant: 6),
            shortcutNote.leadingAnchor.constraint(equalTo: recorder.leadingAnchor),
            shortcutNote.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),

            tapLabel.leadingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor),
            tapLabel.widthAnchor.constraint(equalToConstant: 110),
            tapLabel.centerYAnchor.constraint(equalTo: tapPopup.centerYAnchor),
            tapPopup.topAnchor.constraint(equalTo: shortcutNote.bottomAnchor, constant: 22),
            tapPopup.leadingAnchor.constraint(equalTo: recorder.leadingAnchor),
            tapPopup.widthAnchor.constraint(equalToConstant: 170),
            tapNote.topAnchor.constraint(equalTo: tapPopup.bottomAnchor, constant: 6),
            tapNote.leadingAnchor.constraint(equalTo: recorder.leadingAnchor),
            tapNote.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            permissionButton.topAnchor.constraint(equalTo: tapNote.bottomAnchor, constant: 8),
            permissionButton.leadingAnchor.constraint(equalTo: recorder.leadingAnchor),
            permissionButton.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
    }

    private func refresh() {
        recorder.shortcut = hotKey.shortcut
        if let shortcut = hotKey.shortcut {
            shortcutNote.stringValue = hotKey.isRegistered
                ? "点击按钮后按下新的组合；⌫ 清除，⎋ 取消。"
                : "\(shortcut.display) 已被系统或其他应用占用，请换一个组合。"
            shortcutNote.textColor = hotKey.isRegistered ? .secondaryLabelColor : .systemRed
        } else {
            shortcutNote.stringValue = "未设快捷键，只能连按唤起或从菜单栏打开。"
            shortcutNote.textColor = .secondaryLabelColor
        }

        let trigger = Preferences.doubleTapModifier
        tapPopup.selectItem(at: TapModifier.allCases.firstIndex(of: trigger) ?? 0)
        if trigger == .off {
            tapNote.stringValue = "已关闭。"
            tapNote.textColor = .secondaryLabelColor
            permissionButton.isHidden = true
        } else if doubleTap.isListening {
            tapNote.stringValue = "快速按两下 \(trigger.title) 即可唤起，中间不要按其他键。"
            tapNote.textColor = .secondaryLabelColor
            permissionButton.isHidden = true
        } else {
            tapNote.stringValue = "需要在“系统设置 › 隐私与安全性 › 输入监控”中允许 KongSeek。授权后几秒内自动生效，无需重启。"
            tapNote.textColor = .systemOrange
            permissionButton.isHidden = false
        }
    }

    private func apply(_ shortcut: Shortcut?) {
        Preferences.searchShortcut = shortcut
        hotKey.register(shortcut)
        refresh()
        onChange()
    }

    @objc private func resetShortcut() {
        apply(.defaultSearch)
    }

    @objc private func tapChanged() {
        let index = tapPopup.indexOfSelectedItem
        guard TapModifier.allCases.indices.contains(index) else { return }
        let modifier = TapModifier.allCases[index]
        Preferences.doubleTapModifier = modifier
        doubleTap.trigger = modifier
        doubleTap.refresh()
        if modifier != .off && !doubleTap.hasPermission { doubleTap.requestPermission() }
        refresh()
        onChange()
    }

    @objc private func requestPermission() {
        doubleTap.requestPermission()
        refresh()
    }
}

/// A button that records the next key combination pressed.
final class ShortcutRecorderButton: NSButton {
    var shortcut: Shortcut? {
        didSet { if !isRecording { updateTitle() } }
    }
    var onRecord: ((Shortcut?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private(set) var isRecording = false
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        title = "请按下快捷键…"
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            if plain && event.keyCode == 53 { // Escape: cancel
                self.stopRecording()
            } else if plain && (event.keyCode == 51 || event.keyCode == 117) { // Delete: clear
                self.stopRecording()
                self.onRecord?(nil)
            } else if let shortcut = Shortcut(event: event) {
                self.stopRecording()
                self.onRecord?(shortcut)
            } else {
                NSSound.beep() // needs ⌘, ⌥ or ⌃
            }
            return nil
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        updateTitle()
        onRecordingChange?(false)
    }

    private func updateTitle() {
        title = shortcut?.display ?? "未设置"
    }
}
