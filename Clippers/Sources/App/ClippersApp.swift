import SwiftUI

@main
struct ClippersApp: App {
    @State private var clipboardManager = ClipboardManager()
    @State private var settingsManager = SettingsManager()

    var body: some Scene {
        MenuBarExtra {
            ClipboardPanelView()
                .environment(clipboardManager)
                .environment(settingsManager)
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
