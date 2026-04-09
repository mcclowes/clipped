import Carbon
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(ScreenshotWatcher.self) private var screenshotWatcher
    @Environment(ClipboardManager.self) private var clipboardManager

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

            Section("Content cleanup") {
                ForEach(MutationID.allCases) { mutation in
                    DisclosureGroup(mutation.displayName) {
                        ForEach(ContentType.allCases) { contentType in
                            Toggle(
                                contentType.rawValue,
                                isOn: Binding(
                                    get: { settings.isEnabled(mutation, for: contentType) },
                                    set: { settings.setEnabled(mutation, for: contentType, enabled: $0) }
                                )
                            )
                            .font(.callout)
                        }
                    }
                }

                Text("Mutated items show a ✦ badge. Right-click to restore the original.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Source app overrides") {
                let apps = clipboardManager.recentSourceApps
                if apps.isEmpty {
                    Text("App overrides will appear here once you copy from different apps.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(apps, id: \.bundleID) { app in
                        DisclosureGroup(app.appName) {
                            ForEach(MutationID.allCases) { mutation in
                                let current = settings.isOverridden(mutation, for: app.bundleID)
                                Picker(mutation.displayName, selection: Binding(
                                    get: { overridePickerValue(current) },
                                    set: { newValue in
                                        settings.setOverride(
                                            mutation,
                                            for: app.bundleID,
                                            enabled: overrideFromPicker(newValue)
                                        )
                                    }
                                )) {
                                    Text("Default").tag(0)
                                    Text("On").tag(1)
                                    Text("Off").tag(-1)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }

                Text("Override mutation rules for specific apps. \"Default\" uses the content type setting.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
        .frame(minWidth: 500, idealWidth: 500, minHeight: 450, idealHeight: 550)
    }

    private func overridePickerValue(_ current: Bool?) -> Int {
        switch current {
        case nil: 0
        case true?: 1
        case false?: -1
        }
    }

    private func overrideFromPicker(_ value: Int) -> Bool? {
        switch value {
        case 1: true
        case -1: false
        default: nil
        }
    }
}
