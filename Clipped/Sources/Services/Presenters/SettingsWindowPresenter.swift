import AppKit
import os
import SwiftUI

@MainActor
final class SettingsWindowPresenter {
    private static let logger = Logger(
        subsystem: "com.mcclowes.clipped",
        category: "SettingsWindowPresenter"
    )

    private var settingsWindow: NSWindow?

    /// Opens the settings window. The caller is responsible for closing the panel
    /// presenter before calling this method (mirroring the original `openSettings` behaviour).
    func open(contentView: some View) {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Clipped Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}
