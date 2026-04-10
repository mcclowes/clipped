@testable import Clipped
import Foundation
import Testing

@MainActor
struct OnboardingSeederTests {
    private func freshDefaults(function: String = #function) -> UserDefaults {
        let suiteName = "OnboardingSeederTests.\(function).\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("shouldSeed is true for fresh defaults")
    func seedsOnFreshLaunch() {
        let defaults = freshDefaults()
        #expect(OnboardingSeeder.shouldSeed(defaults: defaults))
    }

    @Test("markSeeded flips shouldSeed to false")
    func markSeededPersists() {
        let defaults = freshDefaults()
        OnboardingSeeder.markSeeded(defaults: defaults)
        #expect(!OnboardingSeeder.shouldSeed(defaults: defaults))
    }

    @Test("Seed items include one per ContentType")
    func coversEachContentType() {
        let items = OnboardingSeeder.makeSeedItems()
        let types = Set(items.map(\.contentType))
        for type in ContentType.allCases {
            #expect(types.contains(type), "missing seed item for \(type)")
        }
    }

    @Test("Plain text welcome appears at the top of the seed list")
    func plainTextAtTop() {
        let items = OnboardingSeeder.makeSeedItems()
        #expect(items.first?.contentType == .plainText)
    }

    @Test("URL seed item has a populated link title")
    func urlItemHasLinkTitle() {
        let items = OnboardingSeeder.makeSeedItems()
        let urlItem = items.first { $0.contentType == .url }
        #expect(urlItem?.linkTitle?.isEmpty == false)
        if case let .url(url)? = urlItem?.content {
            #expect(url.scheme == "https")
        } else {
            Issue.record("expected url content")
        }
    }

    @Test("Rich text seed item carries non-empty RTF data and plain fallback")
    func richTextItemPayload() {
        let items = OnboardingSeeder.makeSeedItems()
        let richItem = items.first { $0.contentType == .richText }
        guard case let .richText(data, plain)? = richItem?.content else {
            Issue.record("expected rich text content")
            return
        }
        #expect(!data.isEmpty)
        #expect(!plain.isEmpty)
    }

    @Test("Image seed item carries non-empty PNG data")
    func imageItemPayload() {
        let items = OnboardingSeeder.makeSeedItems()
        let imageItem = items.first { $0.contentType == .image }
        guard case let .image(data, size)? = imageItem?.content else {
            Issue.record("expected image content")
            return
        }
        #expect(!data.isEmpty)
        #expect(size.width > 0 && size.height > 0)
    }

    @Test("Timestamps are descending so the newest-first order is stable")
    func timestampsDescending() {
        let items = OnboardingSeeder.makeSeedItems()
        let timestamps = items.map(\.timestamp)
        let sorted = timestamps.sorted(by: >)
        #expect(timestamps == sorted)
    }

    @Test("All seed items tag their source app as Clipped")
    func sourceAppAttribution() {
        let items = OnboardingSeeder.makeSeedItems()
        for item in items {
            #expect(item.sourceAppName == "Clipped")
        }
    }
}

@MainActor
struct ClipboardManagerOnboardingTests {
    // swiftlint:disable large_tuple
    private func makeManager() -> (ClipboardManager, MockHistoryStore, MockSettingsManager, UserDefaults) {
        // swiftlint:enable large_tuple
        let manager = ClipboardManager()
        manager.stopMonitoring()
        let history = MockHistoryStore()
        let settings = MockSettingsManager()
        settings.persistAcrossReboots = true
        manager.historyStore = history
        manager.settingsManager = settings
        let suiteName = "ClipboardManagerOnboardingTests.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (manager, history, settings, defaults)
    }

    @Test("Seeds onboarding examples on first launch with empty history")
    func seedsWhenEmpty() async {
        let (manager, history, _, defaults) = makeManager()

        manager.seedOnboardingExamplesIfNeeded(defaults: defaults)
        await manager.flushPendingSaves()

        let types = Set(manager.items.map(\.contentType))
        for type in ContentType.allCases {
            #expect(types.contains(type))
        }
        #expect(await history.saveCallCount > 0)
        #expect(!OnboardingSeeder.shouldSeed(defaults: defaults))
    }

    @Test("Does not seed when history already has items")
    func skipsWhenHistoryPopulated() {
        let (manager, _, _, defaults) = makeManager()
        let existing = ClipboardItem(content: .text("mine"), contentType: .plainText)
        manager.items = [existing]

        manager.seedOnboardingExamplesIfNeeded(defaults: defaults)

        #expect(manager.items.count == 1)
        #expect(manager.items.first?.id == existing.id)
        #expect(!OnboardingSeeder.shouldSeed(defaults: defaults))
    }

    @Test("Does not seed when pinned items already exist")
    func skipsWhenPinned() {
        let (manager, _, _, defaults) = makeManager()
        let pinned = ClipboardItem(content: .text("pinned"), contentType: .plainText, isPinned: true)
        manager.pinnedItems = [pinned]

        manager.seedOnboardingExamplesIfNeeded(defaults: defaults)

        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.count == 1)
    }

    @Test("Does not re-seed after the flag is set")
    func seedsOnlyOnce() {
        let (manager, _, _, defaults) = makeManager()

        manager.seedOnboardingExamplesIfNeeded(defaults: defaults)
        let firstCount = manager.items.count
        manager.items.removeAll()

        manager.seedOnboardingExamplesIfNeeded(defaults: defaults)

        #expect(firstCount > 0)
        #expect(manager.items.isEmpty)
    }
}
