import Carbon
import SwiftUI

struct KeyRecorderView: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    var onChanged: () -> Void

    @State private var isRecording = false
    @State private var eventMonitor: Any?

    private var displayString: String {
        HotkeyManager.formatShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    var body: some View {
        HStack {
            Text(isRecording ? "Press shortcut…" : displayString)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(isRecording ? .orange : .primary)
                .frame(minWidth: 80)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isRecording ? Color.orange.opacity(0.1) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isRecording ? Color.orange : Color.primary.opacity(0.2), lineWidth: 1)
                )

            Button(isRecording ? "Cancel" : "Change") {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }
            .font(.callout)
        }
    }

    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyEvent(event)
            return nil // consume the event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        // Escape cancels recording
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        // Require at least one modifier (except for F-keys)
        let carbonModifiers = carbonModifiers(from: event.modifierFlags)
        let isFunctionKey = (kVK_F1...kVK_F12).contains(Int(event.keyCode))
            || [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20].contains(Int(event.keyCode))

        guard carbonModifiers != 0 || isFunctionKey else { return }

        // Don't allow modifier-only presses
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        guard !modifierKeyCodes.contains(event.keyCode) else { return }

        keyCode = UInt32(event.keyCode)
        modifiers = carbonModifiers
        stopRecording()
        onChanged()
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}
