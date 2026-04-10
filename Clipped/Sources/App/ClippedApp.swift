import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let clipboardManager = ClipboardManager()
    let settingsManager = SettingsManager()
    let screenshotWatcher = ScreenshotWatcher()

    let statusBarController: StatusBarController

    override init() {
        statusBarController = StatusBarController()
        super.init()
        statusBarController.clipboardManager = clipboardManager
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        clipboardManager.settingsManager = settingsManager
        if let mutationService = clipboardManager.mutationService as? ClipboardMutationService {
            mutationService.rulesProvider = settingsManager
        }
        screenshotWatcher.clipboardManager = clipboardManager
        screenshotWatcher.requestNotificationPermission()
        if settingsManager.captureScreenshots,
           let folder = screenshotWatcher.resolveBookmark()
        {
            screenshotWatcher.startWatching(folder: folder)
        }

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
            onClosePanel: { [weak statusBar] in
                statusBar?.close()
            }
        )
        .environment(clipboardManager)
        .environment(settingsManager)

        statusBar.setup(contentView: panelContent)

        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            let onboardingContent = OnboardingView {
                UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
                statusBar.closeOnboarding()
                statusBar.show()
            }
            .environment(settingsManager)
            statusBar.openOnboarding(contentView: onboardingContent)
        }

        HotkeyManager.shared.register(
            keyCode: settingsManager.hotkeyKeyCode,
            modifiers: settingsManager.hotkeyModifiers
        ) { [weak self] in
            guard let self else { return }
            clipboardManager.openedViaHotkey = true
            statusBarController.toggle()
        }
    }
}

@main
struct ClippedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Sticky Note", for: UUID.self) { $itemID in
            if let itemID {
                StickyNoteView(itemID: itemID)
                    .environment(appDelegate.clipboardManager)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 300, height: 200)

        Settings {
            SettingsView()
                .environment(appDelegate.clipboardManager)
                .environment(appDelegate.settingsManager)
                .environment(appDelegate.screenshotWatcher)
        }
    }
}
