import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func presentOnboardingIfNeeded(defaults: UserDefaults = .standard, present: () -> Void) {
        guard !defaults.bool(forKey: "hasLaunchedBefore") else { return }
        present()
        defaults.set(true, forKey: "hasLaunchedBefore")
    }

    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["CLIPPED_TEST_HOST"] == "1" ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil
    }

    @MainActor
    struct Services {
        let clipboardManager: ClipboardManager
        let settingsManager: SettingsManager
        let screenshotWatcher: ScreenshotWatcher
        let statusBarController: StatusBarController

        init() {
            precondition(!AppDelegate.isTestHost, "Live app services must not be created in a test host")
            clipboardManager = ClipboardManager()
            settingsManager = SettingsManager()
            screenshotWatcher = ScreenshotWatcher()
            statusBarController = StatusBarController()
            statusBarController.clipboardManager = clipboardManager
        }
    }

    private let servicesFactory: @MainActor () -> Services
    private lazy var services = servicesFactory()

    var clipboardManager: ClipboardManager {
        services.clipboardManager
    }

    var settingsManager: SettingsManager {
        services.settingsManager
    }

    var screenshotWatcher: ScreenshotWatcher {
        services.screenshotWatcher
    }

    var statusBarController: StatusBarController {
        services.statusBarController
    }

    override convenience init() {
        self.init(servicesFactory: { Services() })
    }

    init(servicesFactory: @escaping @MainActor () -> Services) {
        self.servicesFactory = servicesFactory
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTestHost else { return }

        clipboardManager.settingsManager = settingsManager
        // Repoint an enabled login item at this bundle in case the recorded path is stale.
        settingsManager.repairLoginItemRegistration()
        if let mutationService = clipboardManager.mutationService as? ClipboardMutationService {
            mutationService.rulesProvider = settingsManager
        }
        screenshotWatcher.clipboardManager = clipboardManager
        if settingsManager.captureScreenshots {
            screenshotWatcher.requestNotificationPermission()
            if let folder = screenshotWatcher.resolveBookmark() {
                screenshotWatcher.startWatching(folder: folder)
            }
        }

        statusBarController.hideFromScreenSharing = settingsManager.hideFromScreenSharing
        observeScreenSharingPolicy()

        // Bootstrap the clipboard manager: load persisted history, then start monitoring.
        // This must happen *before* the first poll so persisted items aren't clobbered.
        Task { @MainActor in
            await clipboardManager.bootstrap()
        }

        let statusBar = statusBarController
        let panelContent = ClipboardPanelView(
            onOpenSettings: { [weak self] in
                guard let self else { return }
                let settingsContent = SettingsView()
                    .environment(clipboardManager)
                    .environment(settingsManager)
                    .environment(screenshotWatcher)
                statusBar.openSettings(contentView: settingsContent)
            },
            onOpenHistoryWindow: { [weak self] in
                guard let self else { return }
                let historyContent = HistoryWindowView()
                    .environment(clipboardManager)
                    .environment(settingsManager)
                statusBar.openHistoryWindow(contentView: historyContent)
            },
            onClosePanel: { [weak statusBar] in
                statusBar?.close()
            },
            onCaptureScreenshot: { mode in
                Task { @MainActor in
                    // Let the popover finish closing before macOS freezes the screen image.
                    try? await Task.sleep(for: .milliseconds(150))
                    do {
                        try await ScreenshotCapturer.capture(mode)
                    } catch {
                        NSSound.beep()
                    }
                }
            }
        )
        .environment(clipboardManager)
        .environment(settingsManager)

        statusBar.setup(contentView: panelContent)

        Self.presentOnboardingIfNeeded {
            let onboardingContent = OnboardingView {
                statusBar.closeOnboarding()
                statusBar.show()
            }
            .environment(settingsManager)
            statusBar.openOnboarding(contentView: onboardingContent)
        }

        HotkeyManager.shared.register(
            id: .panel,
            keyCode: settingsManager.hotkeyKeyCode,
            modifiers: settingsManager.hotkeyModifiers
        ) { [weak self] in
            guard let self else { return }
            clipboardManager.openedViaHotkey = true
            statusBarController.toggle()
        }

        HotkeyManager.shared.register(
            id: .historyWindow,
            keyCode: settingsManager.historyWindowHotkeyKeyCode,
            modifiers: settingsManager.historyWindowHotkeyModifiers
        ) { [weak self] in
            guard let self else { return }
            let historyContent = HistoryWindowView()
                .environment(clipboardManager)
                .environment(settingsManager)
            statusBarController.openHistoryWindow(contentView: historyContent)
        }
    }

    /// Drain the debounced history save before the process exits, so the last thing the user
    /// copied (and any just-fetched link title / OCR text) actually reaches disk.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isTestHost else { return .terminateNow }

        Task { @MainActor in
            await clipboardManager.flushPendingSaves()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Re-registers itself on every change so the policy stays mirrored to existing windows
    /// without coupling SettingsView to StatusBarController.
    private func observeScreenSharingPolicy() {
        withObservationTracking {
            _ = settingsManager.hideFromScreenSharing
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.statusBarController.hideFromScreenSharing = self.settingsManager.hideFromScreenSharing
                self.observeScreenSharingPolicy()
            }
        }
    }
}

@main
struct ClippedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Sticky Note", for: UUID.self) { $itemID in
            if !AppDelegate.isTestHost, let itemID {
                StickyNoteView(itemID: itemID)
                    .environment(appDelegate.clipboardManager)
                    .environment(appDelegate.settingsManager)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 300, height: 200)
        .defaultLaunchBehavior(AppDelegate.isTestHost ? .suppressed : .automatic)
        .restorationBehavior(AppDelegate.isTestHost ? .disabled : .automatic)

        Settings {
            if !AppDelegate.isTestHost {
                SettingsView()
                    .environment(appDelegate.clipboardManager)
                    .environment(appDelegate.settingsManager)
                    .environment(appDelegate.screenshotWatcher)
            }
        }
        .defaultLaunchBehavior(AppDelegate.isTestHost ? .suppressed : .automatic)
        .restorationBehavior(AppDelegate.isTestHost ? .disabled : .automatic)
    }
}
