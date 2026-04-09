import Carbon
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(ScreenshotWatcher.self) private var screenshotWatcher

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Persist history across reboots", isOn: $settings.persistAcrossReboots)
                Toggle("Play sound on copy", isOn: $settings.playSoundOnCopy)
                Stepper(
                    "History size: \(settings.maxHistorySize)",
                    value: $settings.maxHistorySize,
                    in: 10...500,
                    step: settings.maxHistorySize >= 100 ? 50 : 10
                )
            }

            Section("Screenshots") {
                Toggle("Capture screenshots to history", isOn: $settings.captureScreenshots)
                    .onChange(of: settings.captureScreenshots) { _, enabled in
                        if enabled {
                            if let folder = screenshotWatcher.resolveBookmark() {
                                screenshotWatcher.startWatching(folder: folder)
                            } else {
                                // Defer modal panel out of SwiftUI view update cycle
                                DispatchQueue.main.async {
                                    if let folder = screenshotWatcher.promptForFolder() {
                                        screenshotWatcher.startWatching(folder: folder)
                                    } else {
                                        settings.captureScreenshots = false
                                    }
                                }
                            }
                        } else {
                            screenshotWatcher.stopWatching()
                        }
                    }

                if settings.captureScreenshots, let folder = screenshotWatcher.watchedFolder {
                    HStack {
                        Text(folder.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Spacer()
                        Button("Change…") {
                            DispatchQueue.main.async {
                                if let newFolder = screenshotWatcher.promptForFolder() {
                                    screenshotWatcher.startWatching(folder: newFolder)
                                }
                            }
                        }
                        .font(.caption)
                    }
                }
            }

            Section("Security") {
                Toggle("Secure mode (password manager entries)", isOn: $settings.secureMode)

                if settings.secureMode {
                    Picker("Password items", selection: $settings.secureTimeout) {
                        Text("Skip entirely").tag(0)
                        Text("Remove after 10s").tag(10)
                        Text("Remove after 30s").tag(30)
                        Text("Remove after 60s").tag(60)
                    }
                }
            }

            Section("Keyboard shortcut") {
                HStack {
                    Text("Open clipboard panel")
                    Spacer()
                    KeyRecorderView(
                        keyCode: $settings.hotkeyKeyCode,
                        modifiers: $settings.hotkeyModifiers,
                        onChanged: {
                            HotkeyManager.shared.reregister(
                                keyCode: settings.hotkeyKeyCode,
                                modifiers: settings.hotkeyModifiers
                            )
                        }
                    )
                }

                Button("Reset to default (⌥C)") {
                    settings.hotkeyKeyCode = 8
                    settings.hotkeyModifiers = UInt32(optionKey)
                    HotkeyManager.shared.reregister(keyCode: 8, modifiers: UInt32(optionKey))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("About") {
                Text("Clipped v1.0.0")
                    .foregroundStyle(.secondary)
                Text("Clipboard history never leaves your device.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 480)
    }
}
