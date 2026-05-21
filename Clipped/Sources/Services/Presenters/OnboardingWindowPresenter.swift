import AppKit
import os
import SwiftUI

@MainActor
final class OnboardingWindowPresenter {
    private static let logger = Logger(
        subsystem: "com.mcclowes.clipped",
        category: "OnboardingWindowPresenter"
    )

    private var onboardingWindow: NSWindow?

    func open(contentView: some View) {
        if let existing = onboardingWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Clipped"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    func close() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }
}
