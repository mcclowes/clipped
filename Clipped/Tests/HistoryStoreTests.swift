@testable import Clipped
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct HistoryStoreTests {
    private func makeEntry(
        text: String,
        isPinned: Bool = false,
        isDeveloperContent: Bool = false
    ) -> StoredEntry {
        let item = ClipboardItem(
            content: .text(text),
            contentType: .plainText,
            isPinned: isPinned,
            isDeveloperContent: isDeveloperContent
        )
        return StoredEntry(item: item)
    }

    @Test("Save and load round-trips items")
    func roundTrip() async {
        let store = HistoryStore()
        await store.clear()

        let entry = makeEntry(text: "test")
        await store.save(entries: [entry])

        let loaded = await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.toClipboardItem()?.plainText == "test")

        await store.clear()
    }

    @Test("Save and load preserves pinned items")
    func pinnedItems() async {
        let store = HistoryStore()
        await store.clear()

        let pinned = makeEntry(text: "pinned", isPinned: true)
        await store.save(entries: [pinned])

        let loaded = await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.isPinned == true)

        await store.clear()
    }

    @Test("Clear removes all stored data")
    func clear() async {
        let store = HistoryStore()
        await store.save(entries: [makeEntry(text: "data")])
        await store.clear()

        let loaded = await store.load()
        #expect(loaded.isEmpty)
    }

    @Test("Load returns empty when no file exists")
    func loadEmpty() async {
        let store = HistoryStore()
        await store.clear()

        let loaded = await store.load()
        #expect(loaded.isEmpty)
    }

    @Test("Conforms to HistoryStoring protocol")
    func protocolConformance() async {
        let store: any HistoryStoring = HistoryStore()
        await store.clear()
        let loaded = await store.load()
        #expect(loaded.isEmpty)
    }

    @Test("StoredEntry preserves mutationsApplied across round-trip")
    func storedEntryMutationsApplied() async {
        let store = HistoryStore()
        await store.clear()

        let item = ClipboardItem(content: .text("cleaned"), contentType: .plainText)
        item.mutationsApplied = ["Stripped tracking parameters"]
        let entry = StoredEntry(item: item)

        await store.save(entries: [entry])
        let loaded = await store.load()
        let restored = loaded.first?.toClipboardItem()
        #expect(restored?.mutationsApplied == ["Stripped tracking parameters"])
        #expect(restored?.wasMutated == true)

        await store.clear()
    }
}
