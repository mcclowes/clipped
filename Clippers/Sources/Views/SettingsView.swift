import SwiftUI

struct SettingsView: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("General") {
                Toggle("Persist history across reboots", isOn: $settings.persistAcrossReboots)
                Stepper(
                    "History size: \(settings.maxHistorySize)",
                    value: $settings.maxHistorySize,
                    in: 5...50
                )
            }

            Section("Security") {
                Toggle("Secure mode (skip password manager entries)", isOn: $settings.secureMode)
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
