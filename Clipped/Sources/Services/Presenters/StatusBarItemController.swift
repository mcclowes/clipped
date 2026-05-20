import AppKit
import os

@MainActor
final class StatusBarItemController {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "StatusBarItemController")

    /// Called when the status-bar button is clicked. The Bool argument is true when
    /// the Option key was held at click time.
    var onClick: ((Bool) -> Void)?

    private var statusItem: NSStatusItem?

    func setup(image: String = "clipboard") {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(systemSymbolName: image, accessibilityDescription: "Clipped")
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    func updateIcon(hasItems: Bool) {
        statusItem?.button?.image = NSImage(
            systemSymbolName: hasItems ? "clipboard.fill" : "clipboard",
            accessibilityDescription: "Clipped"
        )
    }

    var button: NSStatusBarButton? {
        statusItem?.button
    }

    var buttonScreen: NSScreen? {
        statusItem?.button?.window?.screen
    }

    @objc private func statusBarButtonClicked(_: NSStatusBarButton) {
        // Capture modifier state at click time. Reading `NSEvent.modifierFlags` later
        // (from a popover notification) races with the user releasing the key.
        let optionHeld = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        onClick?(optionHeld)
    }
}
