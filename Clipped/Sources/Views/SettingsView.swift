import AppKit
import Carbon
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general = "General"
    case transformations = "Transformations"
    case appRules = "App rules"

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .transformations: "wand.and.stars"
        case .appRules: "app.badge.checkmark"
        }
    }
}

struct SettingsView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(ScreenshotWatcher.self) private var screenshotWatcher
    @Environment(ClipboardManager.self) private var clipboardManager

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Tab(tab.rawValue, systemImage: tab.systemImage, value: tab) {
                    tabContent(for: tab)
                }
            }
        }
        .frame(
            minWidth: 500,
            idealWidth: 500,
            maxWidth: .infinity,
            minHeight: 450,
            idealHeight: 550,
            maxHeight: .infinity
        )
    }

    @ViewBuilder
    private func tabContent(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsTab()
        case .transformations:
            TransformationsSettingsTab()
        case .appRules:
            AppRulesSettingsTab()
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
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
                Picker("History size", selection: $settings.maxHistorySize) {
                    ForEach([10, 25, 50, 100, 250, 500], id: \.self) { size in
                        Text("\(size)").tag(size)
                    }
                }
                .onChange(of: settings.maxHistorySize) { _, _ in
                    // Apply new cap immediately so the UI doesn't lie about its size.
                    clipboardManager.trimToMaxSize()
                }
            }

            Section("Screenshots") {
                Toggle("Capture screenshots to history", isOn: $settings.captureScreenshots)
                    .onChange(of: settings.captureScreenshots) { _, enabled in
                        if enabled {
                            if let folder = screenshotWatcher.resolveBookmark() {
                                screenshotWatcher.startWatching(folder: folder)
                            } else {
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
                        Button("Change\u{2026}") {
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

            Section {
                Toggle("Secure mode (password manager entries)", isOn: $settings.secureMode)

                if settings.secureMode {
                    Picker("Password items", selection: $settings.secureTimeout) {
                        Text("Skip entirely").tag(0)
                        Text("Remove after 10s").tag(10)
                        Text("Remove after 30s").tag(30)
                        Text("Remove after 60s").tag(60)
                    }
                }
            } header: {
                Text("Security")
            } footer: {
                Text("Clipboard history is encrypted at rest with a 256-bit key stored in " +
                    "your login Keychain. The key never leaves this device.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section {
                Toggle("Fetch link previews", isOn: $settings.fetchLinkPreviews)
            } header: {
                Text("Privacy")
            } footer: {
                Text("When enabled, Clipped fetches the title and favicon of copied URLs " +
                    "from their origin server. Disable to keep copied URLs fully local.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section {
                ForEach(ClipboardFilter.contentTypeFilters) { category in
                    FilterCategoryToggleRow(category: category)
                }
            } header: {
                Text("Filter tabs — content type")
            } footer: {
                Text("Show or hide the category tabs above the clipboard history. " +
                    "The \u{201C}All\u{201D} tab is always available.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Filter tabs — smart categories") {
                ForEach(ClipboardFilter.smartCategoryFilters) { category in
                    FilterCategoryToggleRow(category: category)
                }
            }

            Section {
                ForEach(ClipboardFilter.sourceAppFilters) { category in
                    FilterCategoryToggleRow(category: category)
                }
            } header: {
                Text("Filter tabs — source app")
            } footer: {
                Text("Group clipboard items by where they were copied from. Matching is " +
                    "based on bundle identifiers of common apps in each category.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Keyboard shortcuts") {
                HStack {
                    Text("Open clipboard panel")
                    Spacer()
                    KeyRecorderView(
                        keyCode: $settings.hotkeyKeyCode,
                        modifiers: $settings.hotkeyModifiers,
                        onChanged: {
                            HotkeyManager.shared.reregister(
                                id: .panel,
                                keyCode: settings.hotkeyKeyCode,
                                modifiers: settings.hotkeyModifiers
                            )
                        }
                    )
                }

                HStack {
                    Text("Open full history window")
                    Spacer()
                    KeyRecorderView(
                        keyCode: $settings.historyWindowHotkeyKeyCode,
                        modifiers: $settings.historyWindowHotkeyModifiers,
                        onChanged: {
                            HotkeyManager.shared.reregister(
                                id: .historyWindow,
                                keyCode: settings.historyWindowHotkeyKeyCode,
                                modifiers: settings.historyWindowHotkeyModifiers
                            )
                        }
                    )
                }

                Button("Reset to defaults (\u{2325}C, \u{2325}\u{21E7}C)") {
                    settings.hotkeyKeyCode = 8
                    settings.hotkeyModifiers = UInt32(optionKey)
                    HotkeyManager.shared.reregister(
                        id: .panel,
                        keyCode: 8,
                        modifiers: UInt32(optionKey)
                    )
                    settings.historyWindowHotkeyKeyCode = 8
                    settings.historyWindowHotkeyModifiers = UInt32(optionKey | shiftKey)
                    HotkeyManager.shared.reregister(
                        id: .historyWindow,
                        keyCode: 8,
                        modifiers: UInt32(optionKey | shiftKey)
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("About") {
                Text("Clipped v\(Self.appVersion)")
                    .foregroundStyle(.secondary)
                Text(
                    "Clipboard contents stay on your device. The only outbound network " +
                        "requests are link previews (titles and favicons for copied URLs), which " +
                        "can be turned off above."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

private struct FilterCategoryToggleRow: View {
    @Environment(SettingsManager.self) private var settings
    let category: ClipboardFilter

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { !settings.disabledFilterIDs.contains(category.id) },
            set: { newValue in
                if newValue {
                    settings.disabledFilterIDs.remove(category.id)
                } else {
                    settings.disabledFilterIDs.insert(category.id)
                }
            }
        )
    }

    var body: some View {
        Toggle(isOn: isEnabled) {
            HStack(spacing: 8) {
                Image(systemName: category.systemImage)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.label)
                    Text(category.settingsDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Transformations

private struct TransformationsSettingsTab: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                ForEach(MutationID.allCases) { mutation in
                    MutationToggleRow(mutation: mutation)
                }
            } footer: {
                Text("Mutated items show a \u{2726} badge. Right-click to restore the original.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MutationToggleRow: View {
    @Environment(SettingsManager.self) private var settings
    let mutation: MutationID

    private var isEnabled: Binding<Bool> {
        Binding(
            get: {
                mutation.defaultContentTypes.contains { contentType in
                    settings.isEnabled(mutation, for: contentType)
                }
            },
            set: { newValue in
                for contentType in mutation.defaultContentTypes {
                    settings.setEnabled(mutation, for: contentType, enabled: newValue)
                }
            }
        )
    }

    var body: some View {
        Toggle(isOn: isEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(mutation.displayName)
                Text(mutation.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - App rules

private struct AppRulesSettingsTab: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(ClipboardManager.self) private var clipboardManager

    var body: some View {
        Form {
            Section {
                let apps = clipboardManager.recentSourceApps
                if apps.isEmpty {
                    Text("Per-app rules will appear here once you copy from different apps.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(apps, id: \.bundleID) { app in
                        DisclosureGroup {
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
                        } label: {
                            HStack(spacing: 8) {
                                AppIconView(bundleID: app.bundleID)
                                Text(app.appName)
                            }
                        }
                    }
                }
            } footer: {
                Text(
                    "Override transformation rules for specific apps. \"Default\" uses the global setting."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
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

// MARK: - App icon

private struct AppIconView: View {
    let bundleID: String

    var body: some View {
        Group {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
    }

    private var appIcon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
