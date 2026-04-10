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

    @Test("Toggleable filter categories are all enabled by default")
    func defaultFilterCategoriesEnabled() {
        let settings = MockSettingsManager()
        for category in ClipboardFilter.toggleableCategories {
            #expect(!settings.disabledFilterIDs.contains(category.id))
        }
    }

    @Test("Disabled filter IDs round-trip through the setter")
    func disabledFilterIDsRoundTrip() {
        let settings = MockSettingsManager()
        settings.disabledFilterIDs.insert(ClipboardFilter.developer.id)
        #expect(settings.disabledFilterIDs.contains("Developer"))

        settings.disabledFilterIDs.remove(ClipboardFilter.developer.id)
        #expect(!settings.disabledFilterIDs.contains("Developer"))
    }

    @Test("Toggleable category list covers all distinct filter cases")
    func toggleableCategoriesAreUnique() {
        let ids = ClipboardFilter.toggleableCategories.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
