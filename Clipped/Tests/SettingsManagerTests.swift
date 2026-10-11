@testable import Clipped
import Foundation
import Testing

@MainActor
struct SettingsManagerTests {
    private func withSettings(_ body: (SettingsManager, UserDefaults) -> Void) throws {
        let suiteName = "SettingsManagerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(
            SettingsManager(
                defaults: defaults,
                loginItem: MockLoginItem(status: .notRegistered),
                repairsLoginItem: false
            ),
            defaults
        )
    }

    @Test("Defaults max history size to at least 10")
    func defaultMaxHistorySize() throws {
        try withSettings { settings, _ in
            #expect(settings.maxHistorySize >= 10)
        }
    }

    @Test("Defaults secure mode to true")
    func defaultSecureMode() throws {
        try withSettings { settings, _ in
            #expect(settings.secureMode == true)
        }
    }

    @Test("Keeps password-manager items for two minutes by default")
    func defaultSecureTimeout() throws {
        try withSettings { settings, _ in
            #expect(settings.secureTimeout == 120)
        }
    }

    @Test("Masks detected secrets without adding restrictions by default")
    func defaultSecretHandling() throws {
        try withSettings { settings, _ in
            #expect(settings.secretHandling == .maskOnly)
        }
    }

    @Test("Defaults hide-from-screen-sharing to true")
    func defaultHideFromScreenSharing() throws {
        try withSettings { settings, _ in
            #expect(settings.hideFromScreenSharing == true)
        }
    }

    @Test("Conforms to SettingsManaging protocol")
    func protocolConformance() throws {
        try withSettings { settings, _ in
            let manager: any SettingsManaging = settings
            #expect(manager.maxHistorySize >= 10)
        }
    }

    @Test("Settings persist in the supplied store without affecting another store", .bug(id: 127))
    func storesSettingsIndependently() throws {
        try withSettings { settings, defaults in
            settings.secureMode = false
            settings.hideFromScreenSharing = false
            settings.maxHistorySize = 42
            settings.secretHandling = .requireAuthentication
            settings.mutationRules = ["test:plainText": false]
            settings.mutationAppOverrides = ["test:com.example.app": true]
            settings.disabledFilterIDs = [ClipboardFilter.developer.id]

            #expect(defaults.bool(forKey: "hideFromScreenSharing") == false)
            #expect(defaults.integer(forKey: "maxHistorySize") == 42)
            let reloaded = SettingsManager(
                defaults: defaults,
                loginItem: MockLoginItem(status: .notRegistered),
                repairsLoginItem: false
            )
            #expect(reloaded.secureMode == false)
            #expect(reloaded.hideFromScreenSharing == false)
            #expect(reloaded.maxHistorySize == 42)
            #expect(reloaded.secretHandling == .requireAuthentication)
            #expect(reloaded.mutationRules == settings.mutationRules)
            #expect(reloaded.mutationAppOverrides == settings.mutationAppOverrides)
            #expect(reloaded.disabledFilterIDs == settings.disabledFilterIDs)
        }
        try withSettings { settings, _ in
            #expect(settings.secureMode == true)
            #expect(settings.hideFromScreenSharing == true)
            #expect(settings.secretHandling == .maskOnly)
            #expect(settings.mutationRules.isEmpty)
            #expect(settings.mutationAppOverrides.isEmpty)
        }
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
