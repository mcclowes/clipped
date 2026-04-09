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
    var launchAtLogin: Bool { get set }
    var hotkeyKeyCode: UInt32 { get set }
    var hotkeyModifiers: UInt32 { get set }
    var mutationRules: [String: Bool] { get set }
    var mutationAppOverrides: [String: Bool] { get set }
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

    var hotkeyKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode") }
    }

    var hotkeyModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers") }
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

    var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Self.logger.error("Failed to update launch-at-login: \(error.localizedDescription)")
                launchAtLogin.toggle()
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

        let storedKeyCode = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        hotkeyKeyCode = storedKeyCode > 0 ? UInt32(storedKeyCode) : 8 // Default: 'C'
        let storedModifiers = UserDefaults.standard.integer(forKey: "hotkeyModifiers")
        hotkeyModifiers = storedModifiers > 0 ? UInt32(storedModifiers) : UInt32(optionKey) // Default: Option

        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
