import AppKit

extension NSWindow {
    /// Shows the window where it was last left, at the size it was last given (0.26);
    /// centered the first time. Kept under the window's autosave name, or its title.
    func placeRemembered() {
        if frameAutosaveName.isEmpty {
            let name = "KongSeek." + title
            let restored = setFrameUsingName(name)
            setFrameAutosaveName(name)
            if !restored { center() }
        } else if UserDefaults.standard.string(forKey: "NSWindow Frame " + frameAutosaveName) == nil {
            // Autosaving, but never placed yet.
            center()
        }
    }
}

/// Keys every KongSeek window answers the same way (0.26). KongSeek lives in the menu
/// bar and has no Edit menu, so without this ⌘C / ⌘V did nothing in text boxes of its
/// windows, and ⌘W did not close them:
/// ⌘X ⌘C ⌘V ⌘A ⌘Z ⇧⌘Z edit; ⌘W closes; ⌘M minimizes; ⌘F goes to the window's
/// search or filter box. The search and clipboard panels keep their own keys.
enum StandardKeys {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        // Panels (search, clipboard, open / save, alerts) handle their own keys.
        guard let window = event.window, !(window is NSPanel), window.isKeyWindow else { return false }
        // A shortcut recorder (a button) is waiting for the keys themselves.
        if window.firstResponder is NSButton { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if flags == [.command, .shift], key == "z" {
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        }
        guard flags == .command else { return false }
        switch key {
        case "w":
            guard window.styleMask.contains(.closable) else { return false }
            window.performClose(nil)
            return true
        case "m":
            guard window.styleMask.contains(.miniaturizable) else { return false }
            window.miniaturize(nil)
            return true
        case "f":
            return focusSearchBox(in: window)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        default: return false
        }
    }

    /// The window's search field, or else its topmost editable text box.
    private static func focusSearchBox(in window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        var fields: [NSView] = []
        func collect(_ view: NSView) {
            if view.isHiddenOrHasHiddenAncestor { return }
            if let field = view as? NSTextField, field.isEditable, field.isEnabled {
                fields.append(field)
                return
            }
            if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor {
                fields.append(text)
                return
            }
            view.subviews.forEach(collect)
        }
        collect(content)
        let searchFields = fields.filter { $0 is NSSearchField }
        let candidates = searchFields.isEmpty ? fields : searchFields
        // Topmost first (window coordinates grow upwards), then leftmost.
        let ordered = candidates.sorted {
            let a = $0.convert($0.bounds, to: nil), b = $1.convert($1.bounds, to: nil)
            return a.maxY != b.maxY ? a.maxY > b.maxY : a.minX < b.minX
        }
        guard let target = ordered.first, window.makeFirstResponder(target) else { return false }
        if let field = target as? NSTextField { field.currentEditor()?.selectAll(nil) }
        return true
    }
}
