import Carbon
import Observation
import os
import ServiceManagement
import SwiftUI

/// How long an unpinned clipboard item lives before time-based expiry removes it.
/// Pinned items, by design, are exempt from expiry.
enum HistoryRetention: Int, CaseIterable, Identifiable, Codable {
    /// Disables time-based expiry — items live until the size cap evicts them.
    case never = 0
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int {
        rawValue
    }

    var label: String {
        switch self {
        case .never: "Never expire"
        case .oneDay: "After 1 day"
        case .sevenDays: "After 7 days"
        case .thirtyDays: "After 30 days"
        case .ninetyDays: "After 90 days"
        }
    }

    /// Retention duration in seconds, or `nil` when expiry is disabled.
    var interval: TimeInterval? {
        switch self {
        case .never: nil
        default: TimeInterval(rawValue) * 24 * 60 * 60
        }
    }
}

enum SecretHandling: String, CaseIterable, Identifiable, Codable {
    case maskOnly
    case treatLikePasswords
    case requireAuthentication

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .maskOnly: "Mask only"
        case .treatLikePasswords: "Treat like passwords"
        case .requireAuthentication: "Require authentication"
        }
    }

    var detail: String {
        switch self {
        case .maskOnly:
            "Keep secrets in encrypted history. Reveal, copy, export, and paste normally."
        case .treatLikePasswords:
            "Keep secrets in memory for the password timeout, then remove them. Exclude them from saved history."
        case .requireAuthentication:
            "Keep secrets in encrypted history. Authenticate to reveal, copy, or export them; paste normally."
        }
    }
}

@MainActor
protocol SettingsManaging: AnyObject {
    var persistAcrossReboots: Bool { get }
    var maxHistorySize: Int { get }
    var historyRetention: HistoryRetention { get set }
    var secureMode: Bool { get }
    var secureTimeout: Int { get }
    var secretHandling: SecretHandling { get }
    var playSoundOnCopy: Bool { get }
    var captureScreenshots: Bool { get }
    var copyScreenshotsToClipboard: Bool { get }
    var fetchLinkPreviews: Bool { get set }
    var hideFromScreenSharing: Bool { get set }
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
    static let defaultSecureTimeout = 120

    var persistAcrossReboots: Bool {
        didSet { defaults.set(persistAcrossReboots, forKey: "persistAcrossReboots") }
    }

    var maxHistorySize: Int {
        didSet { defaults.set(maxHistorySize, forKey: "maxHistorySize") }
    }

    var historyRetention: HistoryRetention {
        didSet { defaults.set(historyRetention.rawValue, forKey: "historyRetention") }
    }

    var secureMode: Bool {
        didSet { defaults.set(secureMode, forKey: "secureMode") }
    }

    /// Timeout in seconds for secure items.
    var secureTimeout: Int {
        didSet { defaults.set(secureTimeout, forKey: "secureTimeout") }
    }

    var secretHandling: SecretHandling {
        didSet { defaults.set(secretHandling.rawValue, forKey: "secretHandling") }
    }

    var playSoundOnCopy: Bool {
        didSet { defaults.set(playSoundOnCopy, forKey: "playSoundOnCopy") }
    }

    var captureScreenshots: Bool {
        didSet { defaults.set(captureScreenshots, forKey: "captureScreenshots") }
    }

    var copyScreenshotsToClipboard: Bool {
        didSet { defaults.set(copyScreenshotsToClipboard, forKey: "copyScreenshotsToClipboard") }
    }

    var fetchLinkPreviews: Bool {
        didSet { defaults.set(fetchLinkPreviews, forKey: "fetchLinkPreviews") }
    }

    /// When `true`, app-owned windows that surface clipboard contents (panel, history window,
    /// sticky notes) set `NSWindow.sharingType = .none` so they don't appear in screen
    /// captures, recordings, or screen-sharing sessions.
    var hideFromScreenSharing: Bool {
        didSet { defaults.set(hideFromScreenSharing, forKey: "hideFromScreenSharing") }
    }

    var hotkeyKeyCode: UInt32 {
        didSet { defaults.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode") }
    }

    var hotkeyModifiers: UInt32 {
        didSet { defaults.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers") }
    }

    var historyWindowHotkeyKeyCode: UInt32 {
        didSet {
            defaults.set(Int(historyWindowHotkeyKeyCode), forKey: "historyWindowHotkeyKeyCode")
        }
    }

    var historyWindowHotkeyModifiers: UInt32 {
        didSet {
            defaults.set(Int(historyWindowHotkeyModifiers), forKey: "historyWindowHotkeyModifiers")
        }
    }

    /// Per-content-type mutation rules. Key: "mutationID:contentType", Value: enabled.
    var mutationRules: [String: Bool] {
        didSet {
            if let data = try? JSONEncoder().encode(mutationRules) {
                defaults.set(data, forKey: "mutationRules")
            }
        }
    }

    /// Per-source-app overrides. Key: "mutationID:bundleID", Value: enabled.
    var mutationAppOverrides: [String: Bool] {
        didSet {
            if let data = try? JSONEncoder().encode(mutationAppOverrides) {
                defaults.set(data, forKey: "mutationAppOverrides")
            }
        }
    }

    /// IDs of filter tabs the user has hidden from the panel. Stored as disabled rather
    /// than enabled so that new filter categories added in future releases show up by
    /// default without needing a migration.
    var disabledFilterIDs: Set<String> {
        didSet {
            defaults.set(Array(disabledFilterIDs), forKey: "disabledFilterIDs")
        }
    }

    /// Guards against re-entrant `didSet` when we roll back on a failed register/unregister.
    private var isRevertingLaunchAtLogin = false

    /// The most recent error surfaced from SMAppService so settings UI can display it.
    private(set) var launchAtLoginError: String?

    private let defaults: UserDefaults
    private let loginItem: any LoginItemManaging

    /// Debug builds live in DerivedData and vanish on the next clean, so they must never take
    /// silent ownership of the login item. An explicit toggle is still honoured.
    private let repairsLoginItem: Bool

    var launchAtLogin: Bool {
        didSet {
            guard !isRevertingLaunchAtLogin else { return }
            do {
                if launchAtLogin {
                    try loginItem.register()
                } else {
                    try loginItem.unregister()
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

    /// `SMAppService` records the bundle path at registration time and never revisits it. When the
    /// app moves, is replaced by an update, or was registered from a build that has since been
    /// deleted, the login item stays `.enabled` while pointing at a bundle macOS can no longer
    /// launch — the toggle reads "on" and nothing starts at login. Re-registering is idempotent and
    /// repoints the record at the running bundle, so call this once per launch.
    func repairLoginItemRegistration() {
        guard repairsLoginItem, launchAtLogin else { return }
        do {
            try loginItem.register()
            launchAtLoginError = nil
        } catch {
            Self.logger.error("Failed to repair launch-at-login: \(error.localizedDescription)")
            launchAtLoginError = error.localizedDescription
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

    init(
        defaults: UserDefaults = .standard,
        loginItem: any LoginItemManaging = MainAppLoginItem(),
        repairsLoginItem: Bool = SettingsManager.repairsLoginItemByDefault
    ) {
        self.defaults = defaults
        self.loginItem = loginItem
        self.repairsLoginItem = repairsLoginItem
        persistAcrossReboots = defaults.bool(forKey: "persistAcrossReboots")
        let storedSize = defaults.integer(forKey: "maxHistorySize")
        maxHistorySize = storedSize > 0 ? storedSize : ClipboardHistory.defaultMaxHistorySize
        let storedRetention = defaults.integer(forKey: "historyRetention")
        // Default to .never so existing users see no behavior change after upgrade.
        historyRetention = HistoryRetention(rawValue: storedRetention) ?? .never
        secureMode = defaults.object(forKey: "secureMode") == nil
            ? true
            : defaults.bool(forKey: "secureMode")
        let storedSecureTimeout = defaults.integer(forKey: "secureTimeout")
        secureTimeout = storedSecureTimeout > 0 ? storedSecureTimeout : Self.defaultSecureTimeout
        secretHandling = defaults.string(forKey: "secretHandling")
            .flatMap(SecretHandling.init(rawValue:)) ?? .maskOnly
        playSoundOnCopy = defaults.object(forKey: "playSoundOnCopy") == nil
            ? true
            : defaults.bool(forKey: "playSoundOnCopy")
        captureScreenshots = defaults.bool(forKey: "captureScreenshots")
        // Only meaningful while capture is on; default to copying so a capture is ready to paste.
        copyScreenshotsToClipboard = defaults.object(forKey: "copyScreenshotsToClipboard") == nil
            ? true
            : defaults.bool(forKey: "copyScreenshotsToClipboard")
        fetchLinkPreviews = defaults.object(forKey: "fetchLinkPreviews") == nil
            ? true
            : defaults.bool(forKey: "fetchLinkPreviews")
        hideFromScreenSharing = defaults.object(forKey: "hideFromScreenSharing") == nil
            ? true
            : defaults.bool(forKey: "hideFromScreenSharing")

        if let rulesData = defaults.data(forKey: "mutationRules"),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: rulesData)
        {
            mutationRules = decoded
        } else {
            mutationRules = [:]
        }

        if let overridesData = defaults.data(forKey: "mutationAppOverrides"),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: overridesData)
        {
            mutationAppOverrides = decoded
        } else {
            mutationAppOverrides = [:]
        }

        if let stored = defaults.array(forKey: "disabledFilterIDs") as? [String] {
            disabledFilterIDs = Set(stored)
        } else {
            // First launch — default the extended content + source-app filters to hidden
            // so the tab strip stays tidy. Users can opt in from Settings → General.
            disabledFilterIDs = ClipboardFilter.defaultHiddenCategoryIDs
        }

        let storedKeyCode = defaults.integer(forKey: "hotkeyKeyCode")
        hotkeyKeyCode = storedKeyCode > 0 ? UInt32(storedKeyCode) : 8 // Default: 'C'
        let storedModifiers = defaults.integer(forKey: "hotkeyModifiers")
        hotkeyModifiers = storedModifiers > 0 ? UInt32(storedModifiers) : UInt32(optionKey) // Default: Option

        let storedHistoryKeyCode = defaults.integer(forKey: "historyWindowHotkeyKeyCode")
        historyWindowHotkeyKeyCode = storedHistoryKeyCode > 0 ? UInt32(storedHistoryKeyCode) : 8 // Default: 'C'
        let storedHistoryModifiers = defaults.integer(forKey: "historyWindowHotkeyModifiers")
        historyWindowHotkeyModifiers = storedHistoryModifiers > 0
            ? UInt32(storedHistoryModifiers)
            : UInt32(optionKey | shiftKey) // Default: Option+Shift

        let loginItemStatus = loginItem.status
        launchAtLogin = loginItemStatus == .enabled
        if loginItemStatus == .requiresApproval {
            launchAtLoginError = "Clipped is turned off in System Settings → General → Login Items."
        }
    }

    #if DEBUG
        private static let repairsLoginItemByDefault = false
    #else
        private static let repairsLoginItemByDefault = true
    #endif
}
