import Carbon
@testable import Clipped
import Testing

@MainActor
struct HotkeyManagerTests {
    @Test("A failed rebind keeps the previous hotkey and allows another retry")
    func failedRebindKeepsPreviousRegistration() throws {
        let firstRef = try #require(EventHotKeyRef(bitPattern: 1))
        let replacementRef = try #require(EventHotKeyRef(bitPattern: 2))
        var results: [(OSStatus, EventHotKeyRef?)] = [
            (noErr, firstRef),
            (OSStatus(eventHotKeyExistsErr), nil),
            (noErr, replacementRef),
        ]
        var unregistered: [EventHotKeyRef] = []
        let manager = HotkeyManager(registrationSystem: .init(
            register: { _, _, _ in results.removeFirst() },
            unregister: {
                unregistered.append($0)
                return noErr
            }
        ))

        #expect(manager.register(id: .panel, keyCode: 8, modifiers: UInt32(optionKey)) {})
        #expect(manager.reregister(id: .panel, keyCode: 8, modifiers: UInt32(optionKey)))
        #expect(results.count == 2)
        #expect(!manager.reregister(id: .panel, keyCode: 9, modifiers: UInt32(optionKey)))
        #expect(manager.keyCode(for: .panel) == 8)
        #expect(unregistered.isEmpty)

        #expect(manager.reregister(id: .panel, keyCode: 10, modifiers: UInt32(optionKey)))
        #expect(manager.keyCode(for: .panel) == 10)
        #expect(unregistered == [firstRef])
        #expect(manager.lastRegistrationError == nil)
    }

    @Test("An initial registration failure retains the callback for retry")
    func initialFailureRetainsCallback() throws {
        let hotkeyRef = try #require(EventHotKeyRef(bitPattern: 3))
        var results: [(OSStatus, EventHotKeyRef?)] = [
            (OSStatus(eventHotKeyExistsErr), nil),
            (noErr, hotkeyRef),
        ]
        let manager = HotkeyManager(registrationSystem: .init(
            register: { _, _, _ in results.removeFirst() },
            unregister: { _ in noErr }
        ))

        #expect(!manager.register(id: .panel, keyCode: 8, modifiers: UInt32(optionKey)) {})
        #expect(manager.reregister(id: .panel, keyCode: 9, modifiers: UInt32(optionKey)))
        #expect(manager.keyCode(for: .panel) == 9)
    }
}
