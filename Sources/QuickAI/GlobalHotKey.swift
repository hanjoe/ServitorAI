import Carbon

/// Registers a global hotkey via the Carbon Event Manager. No Accessibility
/// permission is required for RegisterEventHotKey.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private let handler: () -> Void

    /// - Parameters:
    ///   - keyCode: virtual key code (e.g. kVK_ANSI_A)
    ///   - modifiers: Carbon modifier flags (cmdKey | shiftKey | optionKey | controlKey)
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x51414B31), id: 1) // "QAK1"

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { hotKey.handler() }
                return noErr
            },
            1,
            [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))],
            userData,
            nil
        )
        guard installStatus == noErr else { return nil }

        let regStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard regStatus == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }
}
