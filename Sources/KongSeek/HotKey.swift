import Carbon
import Foundation

/// A system-wide keyboard shortcut (Carbon hot key: no special permission needed).
final class HotKey {
    let title: String
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Returns nil when the shortcut cannot be registered (e.g. already taken).
    init?(keyCode: UInt32, modifiers: UInt32, title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }
        let installed = InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { return nil }
        let identifier = EventHotKeyID(signature: OSType(0x4B53_4B31), id: 1) // "KSK1"
        let registered = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// ⌥Space, or ⌃⌥Space if ⌥Space is taken by another app.
    static func registerDefault(action: @escaping () -> Void) -> HotKey? {
        let space = UInt32(kVK_Space)
        return HotKey(keyCode: space, modifiers: UInt32(optionKey), title: "⌥空格", action: action)
            ?? HotKey(keyCode: space, modifiers: UInt32(optionKey | controlKey), title: "⌃⌥空格", action: action)
    }
}
