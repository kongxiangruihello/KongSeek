import AppKit
import ServiceManagement
import KongSeekCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var service: IndexService!
    private var searchWindow: SearchWindowController!
    private var hotKey: HotKey!
    private let doubleTap = DoubleTapMonitor()
    private var settingsWindow: SettingsWindowController?
    private var ocr: OCRService!
    private var clipboardHistory: ClipboardHistory!
    private var clipboardMonitor: ClipboardMonitor!
    private var clipboardPanel: ClipboardPanelController!
    private var clipboardHotKey: HotKey!

    func applicationDidFinishLaunching(_ notification: Notification) {
        service = IndexService(roots: Preferences.roots, rules: Preferences.rules)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        ocr = OCRService(directory: support.appendingPathComponent("KongSeek/OCR"))
        ocr.configure(Preferences.ocrSettings)
        searchWindow = SearchWindowController(service: service, ocr: ocr)

        clipboardHistory = ClipboardHistory(store: ClipboardStore(directory: support.appendingPathComponent("KongSeek/Clipboard", isDirectory: true)),
                                            limits: Preferences.clipboardLimits)
        clipboardMonitor = ClipboardMonitor(history: clipboardHistory)
        clipboardPanel = ClipboardPanelController(monitor: clipboardMonitor)
        clipboardPanel.openSettings = { [weak self] in self?.openSettings() }
        clipboardHotKey = HotKey(id: 2) { [weak self] in self?.clipboardPanel.toggle() }
        clipboardHotKey.register(Preferences.clipboardShortcut)
        clipboardMonitor.start()
        service.onStateChange = { [weak self] _ in self?.searchWindow.indexStateChanged() }
        hotKey = HotKey { [weak self] in self?.searchWindow.toggle() }
        hotKey.register(Preferences.searchShortcut)
        doubleTap.onDoubleTap = { [weak self] in self?.searchWindow.toggle() }
        doubleTap.trigger = Preferences.doubleTapModifier
        doubleTap.refresh()
        // Ask once for Input Monitoring (needed for the double tap); later the menu
        // and the settings window show how to grant it.
        if Preferences.doubleTapModifier != .off && !doubleTap.hasPermission && !UserDefaults.standard.bool(forKey: "askedInputMonitoring") {
            UserDefaults.standard.set(true, forKey: "askedInputMonitoring")
            _ = CGRequestListenEventAccess()
            doubleTap.refresh()
        }
        setUpStatusItem()
        service.start()
        if !Preferences.hasLaunchedBefore {
            Preferences.hasLaunchedBefore = true
            searchWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stop()
        clipboardHistory?.flush()
        service.saveNow()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "KongSeek")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt each time it opens, so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        var ways: [String] = []
        if let shortcut = hotKey.shortcut { ways.append(hotKey.isRegistered ? shortcut.display : "\(shortcut.display) 被占用") }
        let trigger = Preferences.doubleTapModifier
        if trigger != .off { ways.append("连按 \(trigger.title)") }
        menu.addItem(item("打开搜索" + (ways.isEmpty ? "" : "（\(ways.joined(separator: " 或 "))）"), #selector(openSearch)))
        if trigger != .off && !doubleTap.isListening {
            menu.addItem(item("⚠︎ 连按 \(trigger.title) 尚未生效：需要“输入监控”权限…", #selector(openSettings)))
        }
        if let shortcut = hotKey.shortcut, !hotKey.isRegistered {
            menu.addItem(item("⚠︎ \(shortcut.display) 已被占用，点此更换…", #selector(openSettings)))
        }
        var clipboardTitle = "剪贴板历史"
        if let shortcut = clipboardHotKey.shortcut { clipboardTitle += "（\(clipboardHotKey.isRegistered ? shortcut.display : shortcut.display + " 被占用")）" }
        menu.addItem(item(clipboardTitle, #selector(openClipboard)))
        if Preferences.clipboardEnabled {
            menu.addItem(item(Preferences.clipboardPaused ? "继续记录剪贴板" : "暂停记录剪贴板", #selector(toggleClipboardPause)))
        }
        menu.addItem(.separator())

        menu.addItem(disabled(stateDescription))
        menu.addItem(item("立即重建索引", #selector(rebuildIndex)))
        menu.addItem(.separator())
        menu.addItem(item("设置…", #selector(openSettings), key: ","))
        menu.addItem(item("关于 KongSeek", #selector(showAbout)))
        menu.addItem(item("退出 KongSeek", #selector(quit), key: "q"))
    }

    private var stateDescription: String {
        switch service.state {
        case .loading:
            return "正在载入索引…"
        case .building(let entries):
            return "正在建立索引 · 已收录 \(entries.formatted()) 项"
        case .ready(let entries, let updated):
            let time = updated.formatted(date: .omitted, time: .shortened)
            return "已索引 \(entries.formatted()) 项 · 更新于 \(time)"
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func openSearch() {
        searchWindow.show()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                hotKey: hotKey,
                doubleTap: doubleTap,
                ocr: ocr,
                clipboardHotKey: clipboardHotKey,
                clipboardMonitor: clipboardMonitor,
                onClipboardSettingsChange: {},
                onIndexSettingsChange: { [weak self] in self?.applySettings() },
                onRebuild: { [weak self] in self?.service.rebuild() },
                indexStatus: { [weak self] in self?.stateDescription ?? "" }
            )
        }
        settingsWindow?.show()
    }

    @objc private func openClipboard() {
        clipboardPanel.show()
    }

    @objc private func toggleClipboardPause() {
        Preferences.clipboardPaused.toggle()
        if !Preferences.clipboardPaused { clipboardMonitor.skipCurrentContents() }
    }

    @objc private func rebuildIndex() {
        service.rebuild()
        searchWindow.show()
    }

    private func applySettings() {
        service.update(roots: Preferences.roots, rules: Preferences.rules)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
