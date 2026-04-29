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

    /// Injected by `AppDelegate` at construction time so the option-click handler can
    /// write to `openedWithOption` without reaching through a global.
    weak var clipboardManager: ClipboardManager?

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var floatingPanel: NSPanel?
    private var eventMonitor: Any?

    /// Builds a fresh `NSHostingController` over the configured SwiftUI panel content. We keep
    /// a builder rather than a single hosting controller because `NSPopover` and the floating
    /// `NSPanel` cannot share one — `NSViewController.parent` is exclusive, so handing the same
    /// controller to the panel detaches it from the popover and produces an empty popover on the
    /// next status-bar-screen click. (See issue #71.)
    private var hostingControllerBuilder: (() -> NSHostingController<AnyView>)?
    private var popoverHosting: NSHostingController<AnyView>?
    private var panelHosting: NSHostingController<AnyView>?

    init() {}

    func setup(contentView: some View) {
        let erased = AnyView(contentView)
        hostingControllerBuilder = {
            let controller = NSHostingController(rootView: erased)
            controller.view.frame = NSRect(origin: .zero, size: Self.panelSize)
            return controller
        }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipped")
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.contentSize = Self.panelSize
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = makePopoverHosting()
    }

    private func makePopoverHosting() -> NSHostingController<AnyView> {
        if let existing = popoverHosting { return existing }
        guard let builder = hostingControllerBuilder else {
            fatalError("StatusBarController.setup must be called before showing")
        }
        let controller = builder()
        popoverHosting = controller
        return controller
    }

    private func makePanelHosting() -> NSHostingController<AnyView> {
        if let existing = panelHosting { return existing }
        guard let builder = hostingControllerBuilder else {
            fatalError("StatusBarController.setup must be called before showing")
        }
        let controller = builder()
        panelHosting = controller
        return controller
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
        clipboardManager?.openedWithOption = optionHeld
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
        let hosting = makePopoverHosting()
        if popover.contentViewController !== hosting {
            popover.contentViewController = hosting
        }
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
            panel.contentViewController = makePanelHosting()
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

    private var historyWindow: NSWindow?

    func openHistoryWindow(contentView: some View) {
        if let existing = historyWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        close()

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Clipboard History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 920, height: 600))
        window.minSize = NSSize(width: 780, height: 460)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = window
    }
}
