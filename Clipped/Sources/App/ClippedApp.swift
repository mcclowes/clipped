import os
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
    private let terminationCoordinator = TerminationCoordinator()

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
                self?.openSettings()
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

    func openSettings() {
        guard !Self.isTestHost else { return }
        let settingsContent = SettingsView()
            .environment(clipboardManager)
            .environment(settingsManager)
            .environment(screenshotWatcher)
        statusBarController.openSettings(contentView: settingsContent)
    }

    /// Stop capture and give the final history save a bounded chance to finish.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isTestHost else { return .terminateNow }

        screenshotWatcher.stopWatching()
        clipboardManager.prepareForTermination()
        terminationCoordinator.begin { [clipboardManager] in
            await clipboardManager.flushPendingSaves()
        } reply: {
            sender.reply(toApplicationShouldTerminate: true)
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

@MainActor
final class TerminationCoordinator {
    nonisolated static let flushDeadline: Duration = .seconds(2)
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "Termination")

    private let waitForDeadline: @Sendable () async throws -> Void
    private var hasBegun = false
    private var replyHandler: (@MainActor () -> Void)?
    private var flushTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    init(waitForDeadline: @escaping @Sendable () async throws -> Void = {
        try await Task.sleep(for: TerminationCoordinator.flushDeadline)
    }) {
        self.waitForDeadline = waitForDeadline
    }

    deinit {
        flushTask?.cancel()
        deadlineTask?.cancel()
    }

    func begin(flush: @escaping @MainActor () async -> Void, reply: @escaping @MainActor () -> Void) {
        guard !hasBegun else { return }
        hasBegun = true
        replyHandler = reply
        // Independent jobs let the deadline reply even when a store ignores cancellation.
        flushTask = Task { [weak self] in
            await flush()
            self?.finish(timedOut: false)
        }
        deadlineTask = Task { [weak self] in
            guard let wait = self?.waitForDeadline else { return }
            do {
                try await wait()
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.finish(timedOut: true)
        }
    }

    private func finish(timedOut: Bool) {
        guard let reply = replyHandler else { return }
        replyHandler = nil
        flushTask?.cancel()
        deadlineTask?.cancel()
        flushTask = nil
        deadlineTask = nil
        if timedOut {
            Self.logger.warning("History flush exceeded the quit deadline; continuing termination")
        }
        reply()
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

        .commands {
            CommandGroup(replacing: .appSettings) {
                if !AppDelegate.isTestHost {
                    Button("Settings…") {
                        appDelegate.openSettings()
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
        }
    }
}
