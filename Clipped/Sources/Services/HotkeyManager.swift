import Carbon
import Cocoa
import os

@MainActor
final class HotkeyManager {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "HotkeyManager")

    static let shared = HotkeyManager()

    private var eventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private var callback: (@MainActor @Sendable () -> Void)?

    private(set) var currentKeyCode: UInt32 = 8
    private(set) var currentModifiers: UInt32 = .init(optionKey)

    var displayString: String {
        Self.formatShortcut(keyCode: currentKeyCode, modifiers: currentModifiers)
    }

    private init() {}

    /// The most recent registration error, if any, so the settings UI can surface it.
    private(set) var lastRegistrationError: String?

    @discardableResult
    func register(
        keyCode: UInt32 = 8,
        modifiers: UInt32 = UInt32(optionKey),
        callback: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        Self.logger.debug("Registering global hotkey")
        self.callback = callback
        currentKeyCode = keyCode
        currentModifiers = modifiers

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

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handlerBlock,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        guard installStatus == noErr else {
            let message = "InstallEventHandler failed (OSStatus \(installStatus))"
            Self.logger.error("\(message)")
            lastRegistrationError = message
            return false
        }

        let hotkeyID = EventHotKeyID(signature: 0x434C_4950, id: 1) // "CLIP"

        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        guard registerStatus == noErr else {
            // eventHotKeyExistsErr = -9878; other conflicts are also mapped as OSStatus.
            let message = "Shortcut is unavailable (already in use or invalid). OSStatus \(registerStatus)."
            Self.logger.error("\(message)")
            lastRegistrationError = message
            return false
        }

        lastRegistrationError = nil
        return true
    }

    func reregister(keyCode: UInt32, modifiers: UInt32) {
        guard let callback else { return }
        unregister()
        register(keyCode: keyCode, modifiers: modifiers, callback: callback)
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

    // MARK: - Display formatting

    static func formatShortcut(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_Escape: "⎋"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        default: "Key(\(keyCode))"
        }
    }
}
