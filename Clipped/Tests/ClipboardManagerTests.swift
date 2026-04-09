import AppKit
@testable import Clipped
import Foundation
import Testing

@MainActor
struct ClipboardManagerTests {
    private func makeManager(persistHistory: Bool = true) -> (ClipboardManager, MockHistoryStore, MockSettingsManager, MockLinkMetadataFetcher) {
        let manager = ClipboardManager()
        manager.stopMonitoring()
        let history = MockHistoryStore()
        let settings = MockSettingsManager()
        settings.persistAcrossReboots = persistHistory
        let fetcher = MockLinkMetadataFetcher()
        manager.historyStore = history
        manager.settingsManager = settings
        manager.linkMetadataFetcher = fetcher
        return (manager, history, settings, fetcher)
    }

    @Test("Starts with empty history")
    func emptyHistory() {
        let (manager, _, _, _) = makeManager()
        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.isEmpty)
    }

    @Test("Filter by content type returns matching items only")
    func filterByType() throws {
        let (manager, _, _, _) = makeManager()

        let textItem = ClipboardItem(content: .text("hello"), contentType: .plainText)
        let urlItem = try ClipboardItem(
            content: .url(#require(URL(string: "https://example.com"))),
            contentType: .url
        )

        manager.items = [textItem, urlItem]
        manager.selectedContentType = .plainText

        #expect(manager.filteredItems.count == 1)
        #expect(manager.filteredItems.first?.contentType == .plainText)
    }

    @Test("Search filters items by preview text")
    func searchFilter() {
        let (manager, _, _, _) = makeManager()

        let item1 = ClipboardItem(content: .text("hello world"), contentType: .plainText)
        let item2 = ClipboardItem(content: .text("goodbye"), contentType: .plainText)

        manager.items = [item1, item2]
        manager.searchQuery = "hello"

        #expect(manager.filteredItems.count == 1)
        #expect(manager.filteredItems.first?.preview.contains("hello") == true)
    }

    @Test("Toggle pin moves item between lists")
    func togglePin() {
        let (manager, history, _, _) = makeManager()
        let item = ClipboardItem(content: .text("pin me"), contentType: .plainText)
        manager.items = [item]

        manager.togglePin(item)

        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.count == 1)
        #expect(item.isPinned == true)
        #expect(history.saveCallCount > 0)

        manager.togglePin(item)

        #expect(manager.items.count == 1)
        #expect(manager.pinnedItems.isEmpty)
        #expect(item.isPinned == false)
    }

    @Test("Remove item removes from correct list")
    func removeItem() {
        let (manager, history, _, _) = makeManager()
        let item = ClipboardItem(content: .text("remove me"), contentType: .plainText)
        manager.items = [item]

        manager.removeItem(item)

        #expect(manager.items.isEmpty)
        #expect(history.saveCallCount > 0)
    }

    @Test("Clear all preserves pinned items by default")
    func clearAllPreservesPinned() {
        let (manager, _, _, _) = makeManager()

        let pinned = ClipboardItem(content: .text("pinned"), contentType: .plainText)
        let unpinned = ClipboardItem(content: .text("unpinned"), contentType: .plainText)

        manager.pinnedItems = [pinned]
        manager.items = [unpinned]

        manager.clearAll()

        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.count == 1)
    }

    @Test("Clear all with includePinned removes everything")
    func clearAllIncludingPinned() {
        let (manager, _, _, _) = makeManager()

        manager.pinnedItems = [ClipboardItem(content: .text("pinned"), contentType: .plainText)]
        manager.items = [ClipboardItem(content: .text("unpinned"), contentType: .plainText)]

        manager.clearAll(includePinned: true)

        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.isEmpty)
    }

    @Test("Trim to max size removes oldest unpinned items")
    func trimToMaxSize() {
        let (manager, _, settings, _) = makeManager()
        settings.maxHistorySize = 10

        for i in 0...15 {
            manager.items.append(
                ClipboardItem(content: .text("item \(i)"), contentType: .plainText)
            )
        }

        manager.trimToMaxSize()

        #expect(manager.items.count == 10)
        #expect(manager.items.first?.preview == "item 0")
    }

    @Test("Trim to max size preserves pinned items")
    func trimPreservesPinned() {
        let (manager, _, settings, _) = makeManager()
        settings.maxHistorySize = 10

        for i in 0...15 {
            let item = ClipboardItem(content: .text("item \(i)"), contentType: .plainText)
            if i == 12 { item.isPinned = true }
            manager.items.append(item)
        }

        manager.trimToMaxSize()

        let pinnedInItems = manager.items.filter(\.isPinned)
        #expect(pinnedInItems.count == 1)
        #expect(pinnedInItems.first?.preview == "item 12")
    }

    @Test("Load persisted history uses history store")
    func loadPersistedHistory() {
        let (manager, history, settings, _) = makeManager()
        settings.persistAcrossReboots = true

        let item = ClipboardItem(content: .text("persisted"), contentType: .plainText)
        history.loadResult = ([item], [])

        manager.loadPersistedHistory()

        #expect(manager.items.count == 1)
        #expect(manager.items.first?.plainText == "persisted")
    }

    @Test("Load persisted history skipped when persistence disabled")
    func loadPersistedHistoryDisabled() {
        let (manager, history, settings, _) = makeManager()
        settings.persistAcrossReboots = false

        let item = ClipboardItem(content: .text("persisted"), contentType: .plainText)
        history.loadResult = ([item], [])

        manager.loadPersistedHistory()

        #expect(manager.items.isEmpty)
    }

    @Test("Save history skipped when persistence disabled")
    func saveHistoryDisabled() {
        let (manager, history, settings, _) = makeManager()
        settings.persistAcrossReboots = false

        manager.items = [ClipboardItem(content: .text("test"), contentType: .plainText)]
        manager.saveHistory()

        #expect(history.saveCallCount == 0)
    }

    @Test("Content type detection")
    func contentTypes() throws {
        let textItem = ClipboardItem(content: .text("plain"), contentType: .plainText)
        #expect(textItem.contentType == .plainText)
        #expect(textItem.plainText == "plain")

        let urlItem = try ClipboardItem(
            content: .url(#require(URL(string: "https://example.com"))),
            contentType: .url
        )
        #expect(urlItem.contentType == .url)
        #expect(urlItem.plainText == "https://example.com")

        let imageItem = ClipboardItem(
            content: .image(Data(), CGSize(width: 100, height: 200)),
            contentType: .image
        )
        #expect(imageItem.preview.contains("100"))
        #expect(imageItem.preview.contains("200"))
    }

    @Test("URL items support link title")
    func linkTitle() throws {
        let urlItem = try ClipboardItem(
            content: .url(#require(URL(string: "https://example.com"))),
            contentType: .url
        )
        #expect(urlItem.linkTitle == nil)

        urlItem.linkTitle = "Example Domain"
        #expect(urlItem.linkTitle == "Example Domain")
    }
}
