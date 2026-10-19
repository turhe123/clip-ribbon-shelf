import AppKit
import Carbon

/// Registers the global "show shelf" shortcut through the Carbon hot key API.
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func registerFromDefaults() {
        let d = UserDefaults.standard
        register(keyCode: UInt32(d.integer(forKey: Prefs.hotKeyCode)),
                 modifiers: UInt32(d.integer(forKey: Prefs.hotKeyModifiers)))
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKeyManager.shared.onPress?() }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        let id = EventHotKeyID(signature: OSType(0x4352_5348), id: 1) // "CRSH"
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { NSLog("ClipRibbonShelf: hot key registration failed (\(status))") }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    /// Converts Cocoa modifier flags into Carbon modifier masks.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        return m
    }

    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }
}
