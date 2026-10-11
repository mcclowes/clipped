import AppKit
import Carbon
@testable import Clipped
import SwiftUI
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

@MainActor
struct KeyRecorderMonitorTests {
    @Test("Dismantling the recorder removes its event monitor exactly once")
    func teardownRemovesMonitor() throws {
        let monitor = MockKeyEventMonitor()
        let coordinator = KeyRecorderMonitor.Coordinator(
            system: monitor.system,
            onCapture: { _, _ in },
            onCancel: {}
        )
        coordinator.start()
        coordinator.start()
        #expect(monitor.additions == 1)

        KeyRecorderMonitor.dismantleNSView(KeyRecorderMonitor.RecorderView(), coordinator: coordinator)
        #expect(monitor.removals == 1)
        coordinator.stop()
        #expect(monitor.removals == 1)
        let handler = try #require(monitor.handler)
        let event = try keyEvent(keyCode: kVK_ANSI_A)
        #expect(handler(event) === event)
    }

    @Test("Unmodified function keys are captured", arguments: [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ])
    func capturesFunctionKey(keyCode: Int) throws {
        let monitor = MockKeyEventMonitor()
        var capturedKeys: [UInt32] = []
        var capturedModifiers: [UInt32] = []
        let coordinator = KeyRecorderMonitor.Coordinator(
            system: monitor.system,
            onCapture: { keyCode, modifiers in
                capturedKeys.append(keyCode)
                capturedModifiers.append(modifiers)
            },
            onCancel: {}
        )
        coordinator.start()
        let handler = try #require(monitor.handler)

        #expect(try handler(keyEvent(keyCode: keyCode)) == nil)
        #expect(capturedKeys == [UInt32(keyCode)])
        #expect(capturedModifiers == [0])
        #expect(monitor.removals == 1)
    }

    @Test("Command-Q cancels recording and remains available to quit")
    func quitShortcutPassesThrough() throws {
        let monitor = MockKeyEventMonitor()
        var captures = 0
        var cancellations = 0
        let coordinator = KeyRecorderMonitor.Coordinator(
            system: monitor.system,
            onCapture: { _, _ in captures += 1 },
            onCancel: { cancellations += 1 }
        )
        coordinator.start()
        let handler = try #require(monitor.handler)
        let event = try keyEvent(keyCode: kVK_ANSI_Q, flags: .command)

        #expect(handler(event) === event)
        #expect(captures == 0)
        #expect(cancellations == 1)
        #expect(monitor.removals == 1)
    }

    @Test("Canceled recording passes keys through before view teardown")
    func cancellationImmediatelyPassesKeysThrough() throws {
        let monitor = MockKeyEventMonitor()
        var recording = true
        var captures = 0
        let coordinator = KeyRecorderMonitor.Coordinator(
            system: monitor.system,
            isRecording: Binding(get: { recording }, set: { recording = $0 }),
            onCapture: { _, _ in captures += 1 },
            onCancel: {}
        )
        coordinator.start()
        let handler = try #require(monitor.handler)
        recording = false
        let event = try keyEvent(keyCode: kVK_ANSI_C, flags: .option)

        #expect(handler(event) === event)
        #expect(captures == 0)
        #expect(monitor.removals == 1)
    }

    @Test("Shortcut modifiers map to Carbon flags", arguments: zip(
        [NSEvent.ModifierFlags.control, .option, .shift, .command, [.control, .option, .shift, .command]],
        [
            UInt32(controlKey),
            UInt32(optionKey),
            UInt32(shiftKey),
            UInt32(cmdKey),
            UInt32(controlKey | optionKey | shiftKey | cmdKey),
        ]
    ))
    func capturesModifiedKey(flags: NSEvent.ModifierFlags, expectedModifiers: UInt32) throws {
        let monitor = MockKeyEventMonitor()
        var capturedKeys: [UInt32] = []
        var capturedModifiers: [UInt32] = []
        let coordinator = KeyRecorderMonitor.Coordinator(
            system: monitor.system,
            onCapture: { keyCode, modifiers in
                capturedKeys.append(keyCode)
                capturedModifiers.append(modifiers)
            },
            onCancel: {}
        )
        coordinator.start()
        let handler = try #require(monitor.handler)
        let event = try keyEvent(keyCode: kVK_ANSI_C, flags: flags)

        #expect(handler(event) == nil)
        #expect(capturedKeys == [UInt32(kVK_ANSI_C)])
        #expect(capturedModifiers == [expectedModifiers])
        #expect(monitor.removals == 1)
        #expect(handler(event) === event)
        #expect(capturedKeys.count == 1)
    }

    @Test("Plain and modifier-only keys wait for a valid shortcut", arguments: zip(
        [kVK_ANSI_A, kVK_UpArrow, kVK_Command, kVK_RightShift],
        [NSEvent.ModifierFlags(rawValue: 0), [], .command, .shift]
    ))
    func ignoresInvalidKeys(keyCode: Int, flags: NSEvent.ModifierFlags) throws {
        let monitor = MockKeyEventMonitor()
        var captures = 0
        let coordinator = KeyRecorderMonitor.Coordinator(
            system: monitor.system,
            onCapture: { _, _ in captures += 1 },
            onCancel: {}
        )
        coordinator.start()
        let handler = try #require(monitor.handler)

        #expect(try handler(keyEvent(keyCode: keyCode, flags: flags)) == nil)
        #expect(captures == 0)
        #expect(monitor.removals == 0)
        #expect(try handler(keyEvent(keyCode: kVK_ANSI_C, flags: .option)) == nil)
        #expect(captures == 1)
        #expect(monitor.removals == 1)
    }

    @Test("Escape cancels without capturing a shortcut")
    func escapeCancels() throws {
        let monitor = MockKeyEventMonitor()
        var captures = 0
        var cancellations = 0
        let coordinator = KeyRecorderMonitor.Coordinator(
            system: monitor.system,
            onCapture: { _, _ in captures += 1 },
            onCancel: { cancellations += 1 }
        )
        coordinator.start()
        let handler = try #require(monitor.handler)

        #expect(try handler(keyEvent(keyCode: kVK_Escape)) == nil)
        #expect(captures == 0)
        #expect(cancellations == 1)
        #expect(monitor.removals == 1)
        let event = try keyEvent(keyCode: kVK_ANSI_C, flags: .option)
        #expect(handler(event) === event)
    }

    @Test("Closing the recorder's retained window cancels monitoring")
    func windowCloseCancelsRecording() throws {
        let monitor = MockKeyEventMonitor()
        var cancellations = 0
        let coordinator = KeyRecorderMonitor.Coordinator(
            system: monitor.system,
            onCapture: { _, _ in },
            onCancel: { cancellations += 1 }
        )
        let view = KeyRecorderMonitor.RecorderView()
        view.coordinator = coordinator
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        coordinator.start()
        window.contentView = view

        let otherWindow = NSWindow()
        otherWindow.isReleasedWhenClosed = false
        otherWindow.close()
        #expect(monitor.removals == 0)
        window.close()

        #expect(monitor.removals == 1)
        #expect(cancellations == 1)
        let handler = try #require(monitor.handler)
        let event = try keyEvent(keyCode: kVK_ANSI_C, flags: .option)
        #expect(handler(event) === event)
    }

    @Test("Detaching the recorder from a window cancels monitoring")
    func windowDetachCancelsRecording() {
        let monitor = MockKeyEventMonitor()
        var cancellations = 0
        let coordinator = KeyRecorderMonitor.Coordinator(
            system: monitor.system,
            onCapture: { _, _ in },
            onCancel: { cancellations += 1 }
        )
        let view = KeyRecorderMonitor.RecorderView()
        view.coordinator = coordinator
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        coordinator.start()
        window.contentView = view
        window.contentView = nil

        #expect(monitor.removals == 1)
        #expect(cancellations == 1)
        window.close()
        #expect(cancellations == 1)
    }

    private func keyEvent(keyCode: Int, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
    }
}
