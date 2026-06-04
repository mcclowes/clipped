import AppKit
import os
import SwiftUI

extension Notification.Name {
    /// Posted by `ClipboardPanelPresenter` immediately *before* the panel content is shown,
    /// for both the popover and the floating-panel presentation paths. The SwiftUI panel
    /// listens for this to decide quick-menu vs. main view. We post our own notification
    /// rather than relying on `NSPopover.willShowNotification` because the floating `NSPanel`
    /// never emits the `NSPopover` notifications.
    static let clippedPanelWillShow = Notification.Name("com.mcclowes.clipped.panelWillShow")

    /// Posted by `ClipboardPanelPresenter` immediately *after* the panel content is shown and
    /// its window is key, for both presentation paths. The SwiftUI panel listens for this to
    /// move first responder into the search field and scroll to the selected row.
    static let clippedPanelDidShow = Notification.Name("com.mcclowes.clipped.panelDidShow")
}

@MainActor
final class ClipboardPanelPresenter {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "ClipboardPanelPresenter")

    private let popover = NSPopover()
    private var floatingPanel: NSPanel?

    /// When `true`, the popover and floating panel set `NSWindow.sharingType = .none` so
    /// clipboard contents stay out of screen captures, recordings, and screen-sharing
    /// sessions. The setter re-applies the policy to already-created windows.
    var hideFromScreenSharing: Bool = true {
        didSet { applyScreenSharingPolicy() }
    }

    /// Builds a fresh `NSHostingController` over the configured SwiftUI panel content. We keep
    /// a builder rather than a single hosting controller because `NSPopover` and the floating
    /// `NSPanel` cannot share one — `NSViewController.parent` is exclusive, so handing the same
    /// controller to the panel detaches it from the popover and produces an empty popover on the
    /// next status-bar-screen click. (See issue #71.)
    private var hostingControllerBuilder: (() -> NSHostingController<AnyView>)?
    private var popoverHosting: NSHostingController<AnyView>?
    private var panelHosting: NSHostingController<AnyView>?

    private let panelSize: NSSize

    init(panelSize: NSSize) {
        self.panelSize = panelSize
    }

    func setup(contentView: some View) {
        let erased = AnyView(contentView)
        hostingControllerBuilder = { [panelSize] in
            let controller = NSHostingController(rootView: erased)
            controller.view.frame = NSRect(origin: .zero, size: panelSize)
            return controller
        }

        popover.contentSize = panelSize
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = makePopoverHosting()
    }

    /// Show the panel. Decides popover vs floating panel based on whether the mouse
    /// is on a different screen than the status-bar button.
    func show(button: NSStatusBarButton, statusBarScreen: NSScreen?) {
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }

        NotificationCenter.default.post(name: .clippedPanelWillShow, object: nil)

        if let mouseScreen, mouseScreen != statusBarScreen {
            showAsPanel(on: mouseScreen)
        } else {
            showAsPopover(button: button)
        }
    }

    func close() {
        popover.performClose(nil)
        closePanel()
    }

    var isShown: Bool {
        popover.isShown || (floatingPanel?.isVisible ?? false)
    }

    // MARK: - Private helpers

    private func makePopoverHosting() -> NSHostingController<AnyView> {
        if let existing = popoverHosting { return existing }
        guard let builder = hostingControllerBuilder else {
            fatalError("ClipboardPanelPresenter.setup must be called before showing")
        }
        let controller = builder()
        popoverHosting = controller
        return controller
    }

    private func makePanelHosting() -> NSHostingController<AnyView> {
        if let existing = panelHosting { return existing }
        guard let builder = hostingControllerBuilder else {
            fatalError("ClipboardPanelPresenter.setup must be called before showing")
        }
        let controller = builder()
        panelHosting = controller
        return controller
    }

    private func showAsPopover(button: NSStatusBarButton) {
        closePanel()
        let hosting = makePopoverHosting()
        if popover.contentViewController !== hosting {
            popover.contentViewController = hosting
        }
        // Activate *before* showing: when triggered by the global hotkey another app is still
        // frontmost, and a popover shown while we're inactive never becomes the key window, so
        // the search field can't take first responder and keyboard navigation is dead.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // The popover's backing window only exists once shown, so apply the screen-sharing
        // policy here rather than at popover construction.
        if let window = popover.contentViewController?.view.window {
            window.sharingType = hideFromScreenSharing ? .none : .readOnly
            window.makeKey()
        }
        NotificationCenter.default.post(name: .clippedPanelDidShow, object: nil)
    }

    private func showAsPanel(on screen: NSScreen) {
        popover.performClose(nil)

        if floatingPanel == nil {
            // No `.nonactivatingPanel`: that style is designed to never become the key window,
            // which would leave the search field unable to take first responder. We want this
            // panel to accept keyboard input, so it must be allowed to become key.
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = true
            panel.sharingType = hideFromScreenSharing ? .none : .readOnly
            panel.contentViewController = makePanelHosting()
            floatingPanel = panel
        }

        let size = panelSize
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.midY - size.height / 2
        floatingPanel?.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        floatingPanel?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .clippedPanelDidShow, object: nil)
    }

    private func closePanel() {
        floatingPanel?.orderOut(nil)
    }

    /// Re-applies the screen-sharing policy to already-created windows so a settings-toggle
    /// change takes effect without re-opening the panel.
    private func applyScreenSharingPolicy() {
        let type: NSWindow.SharingType = hideFromScreenSharing ? .none : .readOnly
        popover.contentViewController?.view.window?.sharingType = type
        floatingPanel?.sharingType = type
    }
}
