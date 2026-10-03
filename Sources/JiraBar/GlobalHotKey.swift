import Carbon.HIToolbox

/// System-wide shortcut via Carbon's RegisterEventHotKey (works without Accessibility permission).
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var handler: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                GlobalHotKey.shared.handler?()
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        let id = EventHotKeyID(signature: OSType(0x4A425452), id: 1)   // 'JBTR'
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { NSLog("JiraBar: couldn't register hotkey (status \(status)) — is it taken by another app?") }
        return status == noErr
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
    }
}
