import Carbon
import Cocoa
import os

@MainActor
final class HotkeyManager {
    /// Identifies a distinct global hotkey slot. `rawValue` is sent through
    /// Carbon's `EventHotKeyID` so incoming events can be routed back to the
    /// matching registration.
    enum HotkeyID: UInt32 {
        case panel = 1
        case historyWindow = 2
    }

    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "HotkeyManager")

    static let shared = HotkeyManager()

    private struct Registration {
        var hotkeyRef: EventHotKeyRef?
        var keyCode: UInt32
        var modifiers: UInt32
        var callback: @MainActor @Sendable () -> Void
    }

    private var eventHandler: EventHandlerRef?
    private var registrations: [HotkeyID: Registration] = [:]

    /// The most recent registration error, if any, so the settings UI can surface it.
    private(set) var lastRegistrationError: String?

    private init() {}

    // MARK: - Introspection

    func keyCode(for id: HotkeyID) -> UInt32 {
        registrations[id]?.keyCode ?? 0
    }

    func modifiers(for id: HotkeyID) -> UInt32 {
        registrations[id]?.modifiers ?? 0
    }

    func displayString(for id: HotkeyID) -> String {
        guard let registration = registrations[id] else { return "" }
        return Self.formatShortcut(keyCode: registration.keyCode, modifiers: registration.modifiers)
    }

    // MARK: - Registration

    @discardableResult
    func register(
        id: HotkeyID,
        keyCode: UInt32,
        modifiers: UInt32,
        callback: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        Self.logger.debug("Registering global hotkey \(id.rawValue)")

        installEventHandlerIfNeeded()

        // Drop any prior registration for this slot before claiming it again.
        if let existingRef = registrations[id]?.hotkeyRef {
            UnregisterEventHotKey(existingRef)
            registrations[id] = nil
        }

        let hotkeyID = EventHotKeyID(signature: 0x434C_4950, id: id.rawValue) // "CLIP"
        var hotkeyRef: EventHotKeyRef?

        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        guard registerStatus == noErr, let hotkeyRef else {
            // eventHotKeyExistsErr = -9878; other conflicts are also mapped as OSStatus.
            let message = "Shortcut is unavailable (already in use or invalid). OSStatus \(registerStatus)."
            Self.logger.error("\(message)")
            lastRegistrationError = message
            return false
        }

        registrations[id] = Registration(
            hotkeyRef: hotkeyRef,
            keyCode: keyCode,
            modifiers: modifiers,
            callback: callback
        )
        lastRegistrationError = nil
        return true
    }

    func reregister(id: HotkeyID, keyCode: UInt32, modifiers: UInt32) {
        guard let existing = registrations[id] else { return }
        register(id: id, keyCode: keyCode, modifiers: modifiers, callback: existing.callback)
    }

    func unregister(id: HotkeyID) {
        if let hotkeyRef = registrations[id]?.hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
        }
        registrations[id] = nil
    }

    private func fire(rawID: UInt32) {
        guard let id = HotkeyID(rawValue: rawID) else { return }
        registrations[id]?.callback()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerBlock: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard status == noErr else { return status }
            let rawID = hkID.id
            Task { @MainActor in
                HotkeyManager.shared.fire(rawID: rawID)
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

        if installStatus != noErr {
            let message = "InstallEventHandler failed (OSStatus \(installStatus))"
            Self.logger.error("\(message)")
            lastRegistrationError = message
        }
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
