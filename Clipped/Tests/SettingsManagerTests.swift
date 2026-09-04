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

    @Test("Keeps password-manager items for two minutes by default")
    func defaultSecureTimeout() {
        let settings = SettingsManager()
        #expect(settings.secureTimeout == 120)
    }

    @Test("Masks detected secrets without adding restrictions by default")
    func defaultSecretHandling() {
        let settings = SettingsManager()
        #expect(settings.secretHandling == .maskOnly)
    }

    @Test("Defaults hide-from-screen-sharing to true")
    func defaultHideFromScreenSharing() {
        let settings = SettingsManager()
        #expect(settings.hideFromScreenSharing == true)
    }

    @Test("Conforms to SettingsManaging protocol")
    func protocolConformance() {
        let settings: any SettingsManaging = SettingsManager()
        #expect(settings.maxHistorySize >= 10)
    }

    @Test("Core content-type filter categories are enabled by default")
    func defaultContentTypeFiltersEnabled() {
        let settings = MockSettingsManager()
        for category in ClipboardFilter.contentTypeFilters {
            #expect(!settings.disabledFilterIDs.contains(category.id))
        }
    }

    @Test("Extended filter categories live in defaultHiddenCategoryIDs")
    func defaultHiddenCategoriesCoverExtendedFilters() {
        let extended = ClipboardFilter.smartCategoryFilters + ClipboardFilter.sourceAppFilters
        for category in extended {
            #expect(ClipboardFilter.defaultHiddenCategoryIDs.contains(category.id))
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

@MainActor
struct LaunchAtLoginTests {
    private func makeSettings(
        loginItem: MockLoginItem,
        repairsLoginItem: Bool = true
    ) -> SettingsManager {
        SettingsManager(loginItem: loginItem, repairsLoginItem: repairsLoginItem)
    }

    @Test("Re-registers an enabled login item on launch so a stale bundle path is repaired")
    func repairsStaleRegistration() {
        let loginItem = MockLoginItem(status: .enabled)
        let settings = makeSettings(loginItem: loginItem)

        #expect(settings.launchAtLogin == true)
        #expect(loginItem.registerCount == 0)

        settings.repairLoginItemRegistration()
        #expect(loginItem.registerCount == 1)
    }

    @Test("Leaves a disabled login item alone on launch")
    func skipsRepairWhenDisabled() {
        let loginItem = MockLoginItem(status: .notRegistered)
        let settings = makeSettings(loginItem: loginItem)

        settings.repairLoginItemRegistration()
        #expect(settings.launchAtLogin == false)
        #expect(loginItem.registerCount == 0)
    }

    @Test("Never repairs from a build that does not own the login item")
    func skipsRepairWhenNotOwning() {
        let loginItem = MockLoginItem(status: .enabled)
        let settings = makeSettings(loginItem: loginItem, repairsLoginItem: false)

        settings.repairLoginItemRegistration()
        #expect(loginItem.registerCount == 0)
    }

    @Test("Surfaces an explanation when the login item is switched off in System Settings")
    func explainsRequiresApproval() {
        let settings = makeSettings(loginItem: MockLoginItem(status: .requiresApproval))

        #expect(settings.launchAtLogin == false)
        #expect(settings.launchAtLoginError?.contains("System Settings") == true)
    }

    @Test("Reverts the toggle and reports the error when registration fails")
    func revertsOnRegistrationFailure() {
        let loginItem = MockLoginItem(status: .notRegistered, registerError: MockLoginItem.Failure.denied)
        let settings = makeSettings(loginItem: loginItem)

        settings.launchAtLogin = true

        #expect(settings.launchAtLogin == false)
        #expect(settings.launchAtLoginError != nil)
    }

    @Test("Turning the toggle off unregisters the login item")
    func unregistersWhenTurnedOff() {
        let loginItem = MockLoginItem(status: .enabled)
        let settings = makeSettings(loginItem: loginItem)

        settings.launchAtLogin = false
        #expect(loginItem.unregisterCount == 1)
        #expect(settings.launchAtLoginError == nil)
    }

    @Test("A failed repair reports the error without flipping the toggle")
    func reportsRepairFailure() {
        let loginItem = MockLoginItem(status: .enabled, registerError: MockLoginItem.Failure.denied)
        let settings = makeSettings(loginItem: loginItem)

        settings.repairLoginItemRegistration()
        #expect(settings.launchAtLogin == true)
        #expect(settings.launchAtLoginError != nil)
    }
}
