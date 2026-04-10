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

    // MARK: - Image file storage

    @Test("Image payloads are stored outside history.json and round-trip on load")
    func imagePayloadsAreStoredExternally() async {
        let store = HistoryStore()
        await store.clear()

        let pngData = Self.onePixelPNG()
        let item = ClipboardItem(
            content: .image(pngData, CGSize(width: 1, height: 1)),
            contentType: .image
        )
        let entry = StoredEntry(item: item)

        await store.save(entries: [entry])

        // history.json should no longer contain the base64 image payload.
        let jsonData = try? Data(contentsOf: Self.historyJSONURL())
        let jsonText = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(jsonText.contains("imageData") == false || jsonText.contains("\"imageData\":null"))

        // The image file should exist on disk next to history.json.
        let imageURL = Self.imageFileURL(id: entry.id, ext: "png")
        #expect(FileManager.default.fileExists(atPath: imageURL.path))

        // Loading round-trips the image data.
        let loaded = await store.load()
        #expect(loaded.first?.imageData == pngData)

        await store.clear()
    }

    @Test("Clearing the store removes image files from disk")
    func clearRemovesImageFiles() async {
        let store = HistoryStore()
        await store.clear()

        let item = ClipboardItem(
            content: .image(Self.onePixelPNG(), CGSize(width: 1, height: 1)),
            contentType: .image
        )
        await store.save(entries: [StoredEntry(item: item)])

        let imageURL = Self.imageFileURL(id: item.id, ext: "png")
        #expect(FileManager.default.fileExists(atPath: imageURL.path))

        await store.clear()
        #expect(!FileManager.default.fileExists(atPath: imageURL.path))
    }

    @Test("Orphaned image files are deleted on subsequent save")
    func orphanedImagesAreDeleted() async {
        let store = HistoryStore()
        await store.clear()

        let itemA = ClipboardItem(
            content: .image(Self.onePixelPNG(), CGSize(width: 1, height: 1)),
            contentType: .image
        )
        let itemB = ClipboardItem(
            content: .image(Self.onePixelPNG(), CGSize(width: 1, height: 1)),
            contentType: .image
        )

        await store.save(entries: [StoredEntry(item: itemA), StoredEntry(item: itemB)])

        let aURL = Self.imageFileURL(id: itemA.id, ext: "png")
        let bURL = Self.imageFileURL(id: itemB.id, ext: "png")
        #expect(FileManager.default.fileExists(atPath: aURL.path))
        #expect(FileManager.default.fileExists(atPath: bURL.path))

        // Save again without itemA — its image file must be removed.
        await store.save(entries: [StoredEntry(item: itemB)])
        #expect(!FileManager.default.fileExists(atPath: aURL.path))
        #expect(FileManager.default.fileExists(atPath: bURL.path))

        await store.clear()
    }

    // MARK: - Fixtures

    private static func onePixelPNG() -> Data {
        Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82,
        ])
    }

    private static func appSupportDir() -> URL {
        // swiftlint:disable:next force_unwrapping
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Clipped", isDirectory: true)
    }

    private static func historyJSONURL() -> URL {
        appSupportDir().appendingPathComponent("history.json")
    }

    private static func imageFileURL(id: UUID, ext: String) -> URL {
        appSupportDir()
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).\(ext)")
    }
}
