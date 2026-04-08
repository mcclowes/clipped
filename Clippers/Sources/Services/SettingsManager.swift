import Observation
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

    init() {
        self.persistAcrossReboots = UserDefaults.standard.bool(forKey: "persistAcrossReboots")
        self.maxHistorySize = max(UserDefaults.standard.integer(forKey: "maxHistorySize"), 10)
        self.secureMode = UserDefaults.standard.object(forKey: "secureMode") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "secureMode")
    }
}
