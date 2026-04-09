import Carbon
import Cocoa

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var eventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private var callback: (@MainActor @Sendable () -> Void)?

    private init() {}

    func register(callback: @escaping @MainActor @Sendable () -> Void) {
        self.callback = callback

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerBlock: EventHandlerUPP = { _, _, _ -> OSStatus in
            Task { @MainActor in
                HotkeyManager.shared.callback?()
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handlerBlock,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        // Option+C
        let hotkeyID = EventHotKeyID(signature: 0x434C_4950, id: 1) // "CLIP"
        let modifiers = UInt32(optionKey)
        let keyCode: UInt32 = 8 // 'C' key

        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
    }

    func unregister() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        callback = nil
    }
}
