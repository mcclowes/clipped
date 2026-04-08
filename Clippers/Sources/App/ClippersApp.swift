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
                    clipboardManager.loadPersistedHistory()
                    if !hasLaunchedBefore {
                        showOnboarding = true
                        hasLaunchedBefore = true
                    }
                    HotkeyManager.shared.register {
                        clipboardManager.openedViaHotkey = true
                        togglePanel()
                    }
                }
        } label: {
            Image(systemName: clipboardManager.items.isEmpty ? "clipboard" : "clipboard.fill")
        }
        .menuBarExtraStyle(.window)
        .defaultSize(width: 320, height: 420)

        WindowGroup("Sticky Note", for: UUID.self) { $itemID in
            if let itemID {
                StickyNoteView(itemID: itemID)
                    .environment(clipboardManager)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 300, height: 200)

        Settings {
            SettingsView()
                .environment(clipboardManager)
                .environment(settingsManager)
        }
    }

    private func togglePanel() {
        // Find the NSStatusBarButton and click it to go through SwiftUI's MenuBarExtra path
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = window.contentView?.subviews.first as? NSStatusBarButton {
                button.performClick(nil)
                return
            }
        }

        // Fallback: directly toggle the panel window
        if let panel = NSApp.windows.first(where: {
            $0 is NSPanel && ($0.className.contains("StatusBarWindow")
                || $0.className.contains("MenuBarExtra"))
        }) {
            if panel.isVisible {
                panel.orderOut(nil)
            } else {
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
