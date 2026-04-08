import SwiftUI

@main
struct ClippersApp: App {
    @State private var clipboardManager = ClipboardManager()
    @State private var settingsManager = SettingsManager()
    @AppStorage("hasLaunchedBefore") private var hasLaunchedBefore = false
    @State private var showOnboarding = false

    var body: some Scene {
        MenuBarExtra {
            ClipboardPanelView(showOnboarding: $showOnboarding)
                .environment(clipboardManager)
                .environment(settingsManager)
                .task {
                    clipboardManager.settingsManager = settingsManager
                    if !hasLaunchedBefore {
                        showOnboarding = true
                        hasLaunchedBefore = true
                    }
                }
        } label: {
            Label("Clippers", systemImage: clipboardManager.items.isEmpty ? "clipboard" : "clipboard.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(clipboardManager)
                .environment(settingsManager)
        }
    }
}
