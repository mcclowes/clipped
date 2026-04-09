import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
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
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 320, height: 420)

        popover.contentSize = NSSize(width: 320, height: 420)
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
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
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

        let panelSize = NSSize(width: 320, height: 420)
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.midY - panelSize.height / 2
        floatingPanel?.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height), display: true)
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
