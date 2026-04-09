import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class SettingsManager {
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
