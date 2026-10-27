import AppKit
import Carbon.HIToolbox

/// A global key combination such as ⌥Space.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// The key's label at recording time, e.g. "F" or "空格".
    var keyLabel: String

    static let defaultSearch = Shortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey), keyLabel: "空格")
    static let defaultClipboard = Shortcut(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(controlKey | optionKey), keyLabel: "V")
    static let defaultLookup = Shortcut(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(controlKey | optionKey), keyLabel: "D")

    var display: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    /// Builds a shortcut from a key press. Requires ⌘, ⌥ or ⌃ so plain typing is never captured.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        guard !modifierKeyCodes.contains(event.keyCode) else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers, keyLabel: Self.label(for: event))
    }

    private static func label(for event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "空格", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(event.keyCode)] { return name }
        let characters = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return characters.isEmpty || characters.unicodeScalars.contains(where: { $0.value < 32 }) ? "键\(event.keyCode)" : characters
    }

    /// Combinations macOS keeps for itself (they would never reach KongSeek).
    var isReservedBySystem: Bool {
        let space = UInt32(kVK_Space)
        let command = UInt32(cmdKey), option = UInt32(optionKey), control = UInt32(controlKey)
        let reserved: [(UInt32, UInt32)] = [
            (space, command),               // Spotlight
            (space, command | option),      // Finder search window
            (space, control),               // previous input source
            (space, control | option),      // next input source
        ]
        return reserved.contains { $0.0 == keyCode && $0.1 == carbonModifiers }
    }
}

/// A global shortcut, registered through Carbon (no special permission needed).
/// Each instance has its own id; events for other ids are passed on.
final class HotKey {
    private(set) var shortcut: Shortcut?
    private let identifier: UInt32
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private static let signature = OSType(0x4B53_4B31) // "KSK1"

    init(id: UInt32 = 1, action: @escaping () -> Void) {
        identifier = id
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr, pressed.signature == HotKey.signature, pressed.id == hotKey.identifier else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    var isRegistered: Bool { hotKeyRef != nil }

    /// Registers `shortcut` (nil clears it). Returns false if macOS or another
    /// app already uses the combination; nothing is registered then.
    @discardableResult
    func register(_ newShortcut: Shortcut?) -> Bool {
        unregister()
        shortcut = newShortcut
        guard let newShortcut else { return true }
        guard !newShortcut.isReservedBySystem else { return false }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let status = RegisterEventHotKey(newShortcut.keyCode, newShortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { hotKeyRef = nil }
        return status == noErr
    }

    /// Temporarily releases the combination (while a new one is being recorded).
    func suspend() {
        unregister()
    }

    func resume() {
        if hotKeyRef == nil, let shortcut { register(shortcut) }
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
