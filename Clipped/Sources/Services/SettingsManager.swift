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
}

@MainActor
@Observable
final class SettingsManager: SettingsManaging {
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

    init() {
        persistAcrossReboots = UserDefaults.standard.bool(forKey: "persistAcrossReboots")
        maxHistorySize = max(UserDefaults.standard.integer(forKey: "maxHistorySize"), 10)
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
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
