import AppKit
import os
import SwiftUI

/// Thin facade that preserves the public API surface consumed by `AppDelegate` and
/// `ClipboardPanelView`. Presentation responsibilities are delegated to the five
/// focused presenters in `Sources/Services/Presenters/`.
@MainActor
final class StatusBarController {
    // MARK: - Public constants (referenced by ClipboardPanelView)

    static let panelWidth: CGFloat = 380
    static let panelHeight: CGFloat = 420
    static var panelSize: NSSize {
        NSSize(width: panelWidth, height: panelHeight)
    }

    /// Injected by `AppDelegate` at construction time so the option-click handler can
    /// write to `openedWithOption` without reaching through a global.
    weak var clipboardManager: ClipboardManager?

    /// When `true`, app-owned windows that surface clipboard contents set
    /// `NSWindow.sharingType = .none` so they stay out of screen captures, recordings,
    /// and screen-sharing sessions. AppDelegate keeps this in sync with the user's
    /// `SettingsManager.hideFromScreenSharing` preference; the setter fans the policy
    /// out to the presenters that own clipboard-content windows.
    var hideFromScreenSharing: Bool = true {
        didSet {
            panel.hideFromScreenSharing = hideFromScreenSharing
            history.hideFromScreenSharing = hideFromScreenSharing
        }
    }

    // MARK: - Presenters

    private let statusBarItem = StatusBarItemController()
    private let panel: ClipboardPanelPresenter
    private let onboarding = OnboardingWindowPresenter()
    private let settings = SettingsWindowPresenter()
    private let history = HistoryWindowPresenter()

    // MARK: - Init

    init() {
        panel = ClipboardPanelPresenter(panelSize: Self.panelSize)

        statusBarItem.onClick = { [weak self] optionHeld in
            guard let self else { return }
            clipboardManager?.openedWithOption = optionHeld
            toggle()
        }
    }

    // MARK: - Setup

    func setup(contentView: some View) {
        statusBarItem.setup()
        panel.setup(contentView: contentView)
    }

    // MARK: - Icon

    func updateIcon(hasItems: Bool) {
        statusBarItem.updateIcon(hasItems: hasItems)
    }

    // MARK: - Panel presentation

    func show() {
        guard let button = statusBarItem.button else { return }
        panel.show(button: button, statusBarScreen: statusBarItem.buttonScreen)
    }

    func close() {
        panel.close()
    }

    func toggle() {
        if isShown {
            close()
        } else {
            show()
        }
    }

    var isShown: Bool {
        panel.isShown
    }

    // MARK: - Onboarding window

    func openOnboarding(contentView: some View) {
        onboarding.open(contentView: contentView)
    }

    func closeOnboarding() {
        onboarding.close()
    }

    // MARK: - Settings window

    func openSettings(contentView: some View) {
        panel.close()
        settings.open(contentView: contentView)
    }

    // MARK: - History window

    func openHistoryWindow(contentView: some View) {
        panel.close()
        history.open(contentView: contentView)
    }
}
