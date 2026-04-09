import SwiftUI

@MainActor
final class AppState: Observable {
    static let shared = AppState()

    let clipboardManager = ClipboardManager()
    let settingsManager = SettingsManager()
    let screenshotWatcher = ScreenshotWatcher()
    var showOnboarding = false

    private init() {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState.shared
        let cm = state.clipboardManager
        let sm = state.settingsManager
        let sw = state.screenshotWatcher

        cm.settingsManager = sm
        cm.loadPersistedHistory()
        sw.clipboardManager = cm
        sw.requestNotificationPermission()
        if sm.captureScreenshots,
           let folder = sw.resolveBookmark()
        {
            sw.startWatching(folder: folder)
        }

        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            state.showOnboarding = true
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        }

        let panelContent = ClipboardPanelView(showOnboarding: Binding(
            get: { AppState.shared.showOnboarding },
            set: { AppState.shared.showOnboarding = $0 }
        ))
        .environment(cm)
        .environment(sm)

        StatusBarController.shared.setup(contentView: panelContent)

        HotkeyManager.shared.register(
            keyCode: sm.hotkeyKeyCode,
            modifiers: sm.hotkeyModifiers
        ) {
            cm.openedViaHotkey = true
            StatusBarController.shared.toggle()
        }
    }
}

@main
struct ClippedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var state = AppState.shared

    var body: some Scene {
        WindowGroup("Sticky Note", for: UUID.self) { $itemID in
            if let itemID {
                StickyNoteView(itemID: itemID)
                    .environment(state.clipboardManager)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 300, height: 200)

        Settings {
            SettingsView()
                .environment(state.clipboardManager)
                .environment(state.settingsManager)
                .environment(state.screenshotWatcher)
        }
    }
}
