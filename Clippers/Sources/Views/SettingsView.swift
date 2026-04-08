import SwiftUI

struct SettingsView: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Persist history across reboots", isOn: $settings.persistAcrossReboots)
                Stepper(
                    "History size: \(settings.maxHistorySize)",
                    value: $settings.maxHistorySize,
                    in: 5...50
                )
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
                Text("⌘⇧V — Open clipboard panel")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("About") {
                Text("Clippers v1.0.0")
                    .foregroundStyle(.secondary)
                Text("Clipboard history never leaves your device.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 320)
    }
}
