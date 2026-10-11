import Carbon
import SwiftUI

struct KeyRecorderView: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    var onChanged: () -> Void

    @State private var isRecording = false

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
                isRecording.toggle()
            }
            .font(.callout)
        }
        .background {
            if isRecording {
                KeyRecorderMonitor(
                    isRecording: $isRecording,
                    onCapture: { capturedKey, capturedModifiers in
                        keyCode = capturedKey
                        modifiers = capturedModifiers
                        isRecording = false
                        onChanged()
                    },
                    onCancel: { isRecording = false }
                )
            }
        }
        .onDisappear { isRecording = false }
    }
}

struct KeyRecorderMonitor: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onCapture: (UInt32, UInt32) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isRecording: $isRecording, onCapture: onCapture, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.coordinator = context.coordinator
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        context.coordinator.isRecording = $isRecording
        context.coordinator.onCapture = onCapture
        context.coordinator.onCancel = onCancel
    }

    static func dismantleNSView(_ nsView: RecorderView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.coordinator = nil
    }

    final class RecorderView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.observeWindow(window)
        }
    }

    @MainActor
    struct MonitorSystem {
        var add: (@escaping @MainActor (NSEvent) -> NSEvent?) -> Any?
        var remove: (Any) -> Void

        static let live = MonitorSystem(
            add: { handler in
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    handler(event)
                }
            },
            remove: NSEvent.removeMonitor
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var isRecording: Binding<Bool>
        var onCapture: (UInt32, UInt32) -> Void
        var onCancel: () -> Void
        private let system: MonitorSystem
        private var eventMonitor: Any?
        private weak var observedWindow: NSWindow?

        init(
            system: MonitorSystem = .live,
            isRecording: Binding<Bool> = .constant(true),
            onCapture: @escaping (UInt32, UInt32) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.system = system
            self.isRecording = isRecording
            self.onCapture = onCapture
            self.onCancel = onCancel
            super.init()
        }

        func start() {
            guard eventMonitor == nil else { return }
            eventMonitor = system.add { [weak self] event in
                guard let self else { return event }
                return handleKeyEvent(event)
            }
        }

        func stop() {
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.willCloseNotification, object: observedWindow
                )
                self.observedWindow = nil
            }
            guard let monitor = eventMonitor else { return }
            system.remove(monitor)
            eventMonitor = nil
        }

        func observeWindow(_ window: NSWindow?) {
            guard let window else {
                cancel()
                return
            }
            guard eventMonitor != nil, observedWindow !== window else { return }
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.willCloseNotification, object: observedWindow
                )
            }
            observedWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }

        @objc private func windowWillClose(_: Notification) {
            cancel()
        }

        private func cancel() {
            guard eventMonitor != nil else { return }
            stop()
            onCancel()
        }

        private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
            guard eventMonitor != nil else { return event }
            guard isRecording.wrappedValue else {
                stop()
                return event
            }
            // Escape cancels recording
            if event.keyCode == UInt16(kVK_Escape) {
                cancel()
                return nil
            }

            if event.keyCode == UInt16(kVK_ANSI_Q), event.modifierFlags.contains(.command) {
                cancel()
                return event
            }

            // Require at least one modifier (except for F-keys)
            let carbonModifiers = carbonModifiers(from: event.modifierFlags)
            let functionKeyCodes: Set<Int> = [
                kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
            ]
            let isFunctionKey = functionKeyCodes.contains(Int(event.keyCode))

            guard carbonModifiers != 0 || isFunctionKey else { return nil }

            // Don't allow modifier-only presses
            let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
            guard !modifierKeyCodes.contains(event.keyCode) else { return nil }

            stop()
            onCapture(UInt32(event.keyCode), carbonModifiers)
            return nil
        }

        private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
            var result: UInt32 = 0
            if flags.contains(.control) {
                result |= UInt32(controlKey)
            }
            if flags.contains(.option) {
                result |= UInt32(optionKey)
            }
            if flags.contains(.shift) {
                result |= UInt32(shiftKey)
            }
            if flags.contains(.command) {
                result |= UInt32(cmdKey)
            }
            return result
        }
    }
}
