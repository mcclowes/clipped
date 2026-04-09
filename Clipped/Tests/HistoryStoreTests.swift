@testable import Clipped
import Foundation
import Testing

@MainActor
struct HistoryStoreTests {
    @Test("Save and load round-trips items")
    func roundTrip() {
        let store = HistoryStore()
        let item = ClipboardItem(content: .text("test"), contentType: .plainText)
        store.save(items: [item], pinnedItems: [])

        let (loaded, pinned) = store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.plainText == "test")
        #expect(pinned.isEmpty)

        store.clear()
    }

    @Test("Save and load preserves pinned items")
    func pinnedItems() {
        let store = HistoryStore()
        let pinned = ClipboardItem(content: .text("pinned"), contentType: .plainText, isPinned: true)
        store.save(items: [], pinnedItems: [pinned])

        let (items, loadedPinned) = store.load()
        #expect(items.isEmpty)
        #expect(loadedPinned.count == 1)
        #expect(loadedPinned.first?.isPinned == true)

        store.clear()
    }

    @Test("Sensitive items are not persisted")
    func sensitiveItemsExcluded() {
        let store = HistoryStore()
        let sensitive = ClipboardItem(content: .text("secret"), contentType: .plainText, isSensitive: true)
        let normal = ClipboardItem(content: .text("normal"), contentType: .plainText)
        store.save(items: [sensitive, normal], pinnedItems: [])

        let (loaded, _) = store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.plainText == "normal")

        store.clear()
    }

    @Test("Clear removes all stored data")
    func clear() {
        let store = HistoryStore()
        store.save(items: [ClipboardItem(content: .text("data"), contentType: .plainText)], pinnedItems: [])
        store.clear()

        let (items, pinned) = store.load()
        #expect(items.isEmpty)
        #expect(pinned.isEmpty)
    }

    @Test("Load returns empty when no file exists")
    func loadEmpty() {
        let store = HistoryStore()
        store.clear()

        let (items, pinned) = store.load()
        #expect(items.isEmpty)
        #expect(pinned.isEmpty)
    }

    @Test("Conforms to HistoryStoring protocol")
    func protocolConformance() {
        let store: any HistoryStoring = HistoryStore()
        store.clear()
        let (items, _) = store.load()
        #expect(items.isEmpty)
    }
}
