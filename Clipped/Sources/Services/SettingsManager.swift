import Carbon
import Observation
import os
import ServiceManagement
import SwiftUI

@MainActor
protocol SettingsManaging: AnyObject {
    var persistAcrossReboots: Bool { get }
    var maxHistorySize: Int { get }
    var secureMode: Bool { get }
    var secureTimeout: Int { get }
    var playSoundOnCopy: Bool { get }
    var captureScreenshots: Bool { get }
    var fetchLinkPreviews: Bool { get set }
    var launchAtLogin: Bool { get set }
    var hotkeyKeyCode: UInt32 { get set }
    var hotkeyModifiers: UInt32 { get set }
    var historyWindowHotkeyKeyCode: UInt32 { get set }
    var historyWindowHotkeyModifiers: UInt32 { get set }
    var mutationRules: [String: Bool] { get set }
    var mutationAppOverrides: [String: Bool] { get set }
    var disabledFilterIDs: Set<String> { get set }
}

@MainActor
@Observable
final class SettingsManager: SettingsManaging, MutationRulesProviding {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "SettingsManager")

    var persistAcrossReboots: Bool {
        didSet { UserDefaults.standard.set(persistAcrossReboots, forKey: "persistAcrossReboots") }
    }

    var maxHistorySize: Int {
        didSet { UserDefaults.standard.set(maxHistorySize, forKey: "maxHistorySize") }
    }

    var secureMode: Bool {
        didSet { UserDefaults.standard.set(secureMode, forKey: "secureMode") }
    }

    /// Timeout in seconds for secure items. 0 means skip entirely.
    var secureTimeout: Int {
        didSet { UserDefaults.standard.set(secureTimeout, forKey: "secureTimeout") }
    }

    var playSoundOnCopy: Bool {
        didSet { UserDefaults.standard.set(playSoundOnCopy, forKey: "playSoundOnCopy") }
    }

    var captureScreenshots: Bool {
        didSet { UserDefaults.standard.set(captureScreenshots, forKey: "captureScreenshots") }
    }

    var fetchLinkPreviews: Bool {
        didSet { UserDefaults.standard.set(fetchLinkPreviews, forKey: "fetchLinkPreviews") }
    }

    var hotkeyKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode") }
    }

    var hotkeyModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers") }
    }

    var historyWindowHotkeyKeyCode: UInt32 {
        didSet {
            UserDefaults.standard.set(Int(historyWindowHotkeyKeyCode), forKey: "historyWindowHotkeyKeyCode")
        }
    }

    var historyWindowHotkeyModifiers: UInt32 {
        didSet {
            UserDefaults.standard.set(Int(historyWindowHotkeyModifiers), forKey: "historyWindowHotkeyModifiers")
        }
    }

    /// Per-content-type mutation rules. Key: "mutationID:contentType", Value: enabled.
    var mutationRules: [String: Bool] {
        didSet {
            if let data = try? JSONEncoder().encode(mutationRules) {
                UserDefaults.standard.set(data, forKey: "mutationRules")
            }
        }
    }

    /// Per-source-app overrides. Key: "mutationID:bundleID", Value: enabled.
    var mutationAppOverrides: [String: Bool] {
        didSet {
            if let data = try? JSONEncoder().encode(mutationAppOverrides) {
                UserDefaults.standard.set(data, forKey: "mutationAppOverrides")
            }
        }
    }

    /// IDs of filter tabs the user has hidden from the panel. Stored as disabled rather
    /// than enabled so that new filter categories added in future releases show up by
    /// default without needing a migration.
    var disabledFilterIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(disabledFilterIDs), forKey: "disabledFilterIDs")
        }
    }

    /// Guards against re-entrant `didSet` when we roll back on a failed register/unregister.
    private var isRevertingLaunchAtLogin = false

    /// The most recent error surfaced from SMAppService so settings UI can display it.
    private(set) var launchAtLoginError: String?

    var launchAtLogin: Bool {
        didSet {
            guard !isRevertingLaunchAtLogin else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginError = nil
            } catch {
                Self.logger.error("Failed to update launch-at-login: \(error.localizedDescription)")
                launchAtLoginError = error.localizedDescription
                isRevertingLaunchAtLogin = true
                launchAtLogin = oldValue
                isRevertingLaunchAtLogin = false
            }
        }
    }

    // MARK: - MutationRulesProviding

    func isEnabled(_ mutationID: MutationID, for contentType: ContentType) -> Bool {
        let key = "\(mutationID.rawValue):\(contentType.rawValue)"
        return mutationRules[key] ??
            (mutationID.defaultContentTypes.contains(contentType) && mutationID.enabledByDefault)
    }

    func isOverridden(_ mutationID: MutationID, for bundleID: String) -> Bool? {
        let key = "\(mutationID.rawValue):\(bundleID)"
        return mutationAppOverrides[key]
    }

    func setEnabled(_ mutationID: MutationID, for contentType: ContentType, enabled: Bool) {
        let key = "\(mutationID.rawValue):\(contentType.rawValue)"
        mutationRules[key] = enabled
    }

    func setOverride(_ mutationID: MutationID, for bundleID: String, enabled: Bool?) {
        let key = "\(mutationID.rawValue):\(bundleID)"
        mutationAppOverrides[key] = enabled
    }

    init() {
        persistAcrossReboots = UserDefaults.standard.bool(forKey: "persistAcrossReboots")
        let storedSize = UserDefaults.standard.integer(forKey: "maxHistorySize")
        maxHistorySize = storedSize > 0 ? storedSize : 100
        secureMode = UserDefaults.standard.object(forKey: "secureMode") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "secureMode")
        secureTimeout = UserDefaults.standard.object(forKey: "secureTimeout") == nil
            ? 0
            : UserDefaults.standard.integer(forKey: "secureTimeout")
        playSoundOnCopy = UserDefaults.standard.object(forKey: "playSoundOnCopy") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "playSoundOnCopy")
        captureScreenshots = UserDefaults.standard.bool(forKey: "captureScreenshots")
        fetchLinkPreviews = UserDefaults.standard.object(forKey: "fetchLinkPreviews") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "fetchLinkPreviews")

        if let rulesData = UserDefaults.standard.data(forKey: "mutationRules"),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: rulesData)
        {
            mutationRules = decoded
        } else {
            mutationRules = [:]
        }

        if let overridesData = UserDefaults.standard.data(forKey: "mutationAppOverrides"),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: overridesData)
        {
            mutationAppOverrides = decoded
        } else {
            mutationAppOverrides = [:]
        }

        if let stored = UserDefaults.standard.array(forKey: "disabledFilterIDs") as? [String] {
            disabledFilterIDs = Set(stored)
        } else {
            // First launch — default the extended content + source-app filters to hidden
            // so the tab strip stays tidy. Users can opt in from Settings → General.
            disabledFilterIDs = ClipboardFilter.defaultHiddenCategoryIDs
        }

        let storedKeyCode = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        hotkeyKeyCode = storedKeyCode > 0 ? UInt32(storedKeyCode) : 8 // Default: 'C'
        let storedModifiers = UserDefaults.standard.integer(forKey: "hotkeyModifiers")
        hotkeyModifiers = storedModifiers > 0 ? UInt32(storedModifiers) : UInt32(optionKey) // Default: Option

        let storedHistoryKeyCode = UserDefaults.standard.integer(forKey: "historyWindowHotkeyKeyCode")
        historyWindowHotkeyKeyCode = storedHistoryKeyCode > 0 ? UInt32(storedHistoryKeyCode) : 8 // Default: 'C'
        let storedHistoryModifiers = UserDefaults.standard.integer(forKey: "historyWindowHotkeyModifiers")
        historyWindowHotkeyModifiers = storedHistoryModifiers > 0
            ? UInt32(storedHistoryModifiers)
            : UInt32(optionKey | shiftKey) // Default: Option+Shift

        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
