@testable import Clipped
import Testing

@MainActor
struct SettingsManagerTests {
    @Test("Defaults max history size to at least 10")
    func defaultMaxHistorySize() {
        let settings = SettingsManager()
        #expect(settings.maxHistorySize >= 10)
    }

    @Test("Defaults secure mode to true")
    func defaultSecureMode() {
        let settings = SettingsManager()
        #expect(settings.secureMode == true)
    }

    @Test("Conforms to SettingsManaging protocol")
    func protocolConformance() {
        let settings: any SettingsManaging = SettingsManager()
        #expect(settings.maxHistorySize >= 10)
    }
}
