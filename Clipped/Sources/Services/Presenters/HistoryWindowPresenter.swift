import AppKit
import os
import SwiftUI

@MainActor
final class HistoryWindowPresenter {
    private static let logger = Logger(
        subsystem: "com.mcclowes.clipped",
        category: "HistoryWindowPresenter"
    )

    private var historyWindow: NSWindow?

    /// When `true`, the history window sets `NSWindow.sharingType = .none` so clipboard
    /// contents stay out of screen captures, recordings, and screen-sharing sessions.
    var hideFromScreenSharing: Bool = true {
        didSet { historyWindow?.sharingType = hideFromScreenSharing ? .none : .readOnly }
    }

    /// Opens the history window. The caller is responsible for closing the panel
    /// presenter before calling this method (mirroring the original `openHistoryWindow` behaviour).
    func open(contentView: some View) {
        if let existing = historyWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Clipboard History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 920, height: 600))
        window.minSize = NSSize(width: 780, height: 460)
        window.center()
        window.isReleasedWhenClosed = false
        window.sharingType = hideFromScreenSharing ? .none : .readOnly
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = window
    }
}
