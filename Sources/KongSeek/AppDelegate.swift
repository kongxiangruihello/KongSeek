import AppKit
import ServiceManagement
import KongSeekCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var service: IndexService!
    private var searchWindow: SearchWindowController!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        service = IndexService(roots: Preferences.roots, rules: Preferences.rules)
        searchWindow = SearchWindowController(service: service)
        service.onStateChange = { [weak self] _ in self?.searchWindow.indexStateChanged() }
        hotKey = HotKey.registerDefault { [weak self] in self?.searchWindow.toggle() }
        setUpStatusItem()
        service.start()
        if !Preferences.hasLaunchedBefore {
            Preferences.hasLaunchedBefore = true
            searchWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        let shortcut = hotKey.map { "（\($0.title)）" } ?? "（快捷键未能注册）"
        menu.addItem(item("打开搜索" + shortcut, #selector(openSearch)))
        menu.addItem(.separator())

        menu.addItem(disabled(stateDescription))
        menu.addItem(item("立即重建索引", #selector(rebuildIndex)))

        let folders = NSMenu()
        for (offset, root) in Preferences.roots.enumerated() {
            let entry = NSMenuItem(title: (root as NSString).abbreviatingWithTildeInPath, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let reveal = item("在访达中显示", #selector(revealRoot(_:)))
            reveal.tag = offset
            let remove = item("不再索引这个文件夹", #selector(removeRoot(_:)))
            remove.tag = offset
            submenu.addItem(reveal)
            submenu.addItem(remove)
            entry.submenu = submenu
            folders.addItem(entry)
        }
        folders.addItem(.separator())
        folders.addItem(item("添加文件夹…", #selector(addRoot)))
        folders.addItem(item("恢复默认（主目录、iCloud 云盘、应用程序）", #selector(resetRoots)))
        let foldersItem = NSMenuItem(title: "索引的文件夹", action: nil, keyEquivalent: "")
        foldersItem.submenu = folders
        menu.addItem(foldersItem)

        let hidden = item("包含隐藏文件", #selector(toggleHidden))
        hidden.state = Preferences.includeHidden ? .on : .off
        menu.addItem(hidden)
        let pathMatch = item("关键词也匹配所在文件夹", #selector(togglePathMatch))
        pathMatch.state = Preferences.matchFolderPath ? .on : .off
        menu.addItem(pathMatch)
        menu.addItem(.separator())

        let login = item("登录时自动启动", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
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

    @objc private func rebuildIndex() {
        service.rebuild()
        searchWindow.show()
    }

    @objc private func revealRoot(_ sender: NSMenuItem) {
        let roots = Preferences.roots
        guard roots.indices.contains(sender.tag) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: roots[sender.tag])])
    }

    @objc private func removeRoot(_ sender: NSMenuItem) {
        var roots = Preferences.roots
        guard roots.indices.contains(sender.tag) else { return }
        roots.remove(at: sender.tag)
        Preferences.roots = roots
        applySettings()
    }

    @objc private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "索引"
        panel.message = "选择要让 KongSeek 索引的文件夹"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        var roots = Preferences.roots
        for url in panel.urls where !roots.contains(url.path) { roots.append(url.path) }
        Preferences.roots = roots
        applySettings()
    }

    @objc private func resetRoots() {
        Preferences.resetRoots()
        applySettings()
    }

    @objc private func toggleHidden() {
        Preferences.includeHidden.toggle()
        applySettings()
    }

    @objc private func togglePathMatch() {
        Preferences.matchFolderPath.toggle()
        if searchWindow.isVisible { searchWindow.runSearch() }
    }

    private func applySettings() {
        service.update(roots: Preferences.roots, rules: Preferences.rules)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法更改登录启动设置"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
