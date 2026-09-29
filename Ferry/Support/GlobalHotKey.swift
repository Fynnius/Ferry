import AppKit
import Carbon.HIToolbox

/// ⌃⌥⌘F anywhere brings Ferry to the front (opt-in). Carbon's RegisterEventHotKey
/// needs no Accessibility permission, unlike event taps.
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    static let displayString = "⌃⌥⌘F"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?

    func setEnabled(_ enabled: Bool) {
        enabled ? register() : unregister()
    }

    private func register() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x46525259), id: 1) // 'FRRY'
        RegisterEventHotKey(UInt32(kVK_ANSI_F), UInt32(cmdKey | optionKey | controlKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
