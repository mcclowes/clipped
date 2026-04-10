import AppKit
import os
import SwiftUI

@MainActor
final class StatusBarController {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "StatusBarController")

    static let panelWidth: CGFloat = 380
    static let panelHeight: CGFloat = 420
    static var panelSize: NSSize {
        NSSize(width: panelWidth, height: panelHeight)
    }

    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var floatingPanel: NSPanel?
    private var eventMonitor: Any?

    private init() {}

    func setup(contentView: some View) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipped")
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let hostingController = NSHostingController(rootView: contentView)
        hostingController.view.frame = NSRect(origin: .zero, size: Self.panelSize)

        popover.contentSize = Self.panelSize
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
    }

    func updateIcon(hasItems: Bool) {
        statusItem?.button?.image = NSImage(
            systemSymbolName: hasItems ? "clipboard.fill" : "clipboard",
            accessibilityDescription: "Clipped"
        )
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        // Capture modifier state at click time. Reading `NSEvent.modifierFlags` later
        // (from a popover notification) races with the user releasing the key.
        let optionHeld = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        AppState.shared.clipboardManager.openedWithOption = optionHeld
        toggle()
    }

    func toggle() {
        if isShown {
            close()
        } else {
            show()
        }
    }

    func show() {
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        let statusBarScreen = statusItem?.button?.window?.screen

        if let mouseScreen, mouseScreen != statusBarScreen {
            showAsPanel(on: mouseScreen)
        } else {
            showAsPopover()
        }
    }

    private func showAsPopover() {
        guard let button = statusItem?.button else { return }
        closePanel()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showAsPanel(on screen: NSScreen) {
        popover.performClose(nil)

        if floatingPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: Self.panelSize),
                styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = true
            panel.contentViewController = popover.contentViewController
            floatingPanel = panel
        }

        let size = Self.panelSize
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.midY - size.height / 2
        floatingPanel?.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        floatingPanel?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        floatingPanel?.makeKey()
    }

    private func closePanel() {
        floatingPanel?.orderOut(nil)
    }

    func close() {
        popover.performClose(nil)
        closePanel()
    }

    var isShown: Bool {
        popover.isShown || (floatingPanel?.isVisible ?? false)
    }

    private var onboardingWindow: NSWindow?

    func openOnboarding(contentView: some View) {
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

    func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    private var settingsWindow: NSWindow?

    func openSettings(contentView: some View) {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        close()

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
