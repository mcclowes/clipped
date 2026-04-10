@testable import Clipped
import CryptoKit
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct HistoryStoreTests {
    private func makeStore(
        keyStore: any KeychainKeyStoring = InMemoryKeyStore()
    ) -> HistoryStore {
        HistoryStore(keyStore: keyStore)
    }

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
        let store = makeStore()
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
        let store = makeStore()
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
        let store = makeStore()
        await store.save(entries: [makeEntry(text: "data")])
        await store.clear()

        let loaded = await store.load()
        #expect(loaded.isEmpty)
    }

    @Test("Load returns empty when no file exists")
    func loadEmpty() async {
        let store = makeStore()
        await store.clear()

        let loaded = await store.load()
        #expect(loaded.isEmpty)
    }

    @Test("Conforms to HistoryStoring protocol")
    func protocolConformance() async {
        let store: any HistoryStoring = makeStore()
        await store.clear()
        let loaded = await store.load()
        #expect(loaded.isEmpty)
    }

    @Test("StoredEntry preserves mutationsApplied across round-trip")
    func storedEntryMutationsApplied() async {
        let store = makeStore()
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

    // MARK: - Encryption

    @Test("history.enc ciphertext does not contain plaintext content")
    func encryptedFileDoesNotContainPlaintext() async {
        let store = makeStore()
        await store.clear()

        let secret = "definitely-secret-plaintext-token-abc123"
        await store.save(entries: [makeEntry(text: secret)])

        let data = try? Data(contentsOf: Self.historyEncURL())
        #expect(data != nil)
        if let data {
            let needle = Data(secret.utf8)
            #expect(data.range(of: needle) == nil)
        }

        await store.clear()
    }

    @Test("Plaintext history.json is NOT left on disk after a save")
    func noPlaintextHistoryFile() async {
        let store = makeStore()
        await store.clear()

        await store.save(entries: [makeEntry(text: "hi")])

        #expect(!FileManager.default.fileExists(atPath: Self.historyJSONURL().path))
        #expect(FileManager.default.fileExists(atPath: Self.historyEncURL().path))

        await store.clear()
    }

    @Test("Re-saving with a different key fails to decrypt old data")
    func differentKeyCannotDecrypt() async {
        let keyStore1 = InMemoryKeyStore()
        let store1 = makeStore(keyStore: keyStore1)
        await store1.clear()
        await store1.save(entries: [makeEntry(text: "top secret")])

        // A brand-new key store + store instance should refuse the old file.
        let keyStore2 = InMemoryKeyStore()
        let store2 = makeStore(keyStore: keyStore2)
        let loaded = await store2.load()
        #expect(loaded.isEmpty)
        let error = await store2.lastLoadError()
        #expect(error == .decryptionFailed)

        await store2.startFresh()
    }

    @Test("startFresh wipes encrypted data and clears error state")
    func startFreshRecovery() async {
        let keyStore1 = InMemoryKeyStore()
        let store1 = makeStore(keyStore: keyStore1)
        await store1.clear()
        await store1.save(entries: [makeEntry(text: "old data")])

        let keyStore2 = InMemoryKeyStore()
        let store2 = makeStore(keyStore: keyStore2)
        _ = await store2.load()
        #expect(await store2.lastLoadError() == .decryptionFailed)

        await store2.startFresh()
        #expect(await store2.lastLoadError() == nil)
        #expect(!FileManager.default.fileExists(atPath: Self.historyEncURL().path))

        // New saves should work afterwards.
        await store2.save(entries: [makeEntry(text: "fresh")])
        let loaded = await store2.load()
        #expect(loaded.count == 1)

        await store2.clear()
    }

    @Test("Corrupted ciphertext surfaces a load error")
    func corruptedCiphertext() async {
        let store = makeStore()
        await store.clear()
        await store.save(entries: [makeEntry(text: "hi")])

        // Overwrite history.enc with nonsense that's still longer than the crypto overhead
        // so we exercise the `.decryptionFailed` path specifically.
        let junk = Data(repeating: 0x41, count: 128)
        try? junk.write(to: Self.historyEncURL())

        let loaded = await store.load()
        #expect(loaded.isEmpty)
        #expect(await store.lastLoadError() == .decryptionFailed)

        await store.clear()
    }

    // MARK: - Legacy plaintext migration

    @Test("Legacy plaintext history.json is migrated to history.enc on first load")
    func migratesLegacyPlaintextHistory() async throws {
        let keyStore = InMemoryKeyStore()
        let store = makeStore(keyStore: keyStore)
        await store.clear()

        // Hand-craft a plaintext history.json like a previous app version would have written.
        let legacy = makeEntry(text: "from before the upgrade")
        let plaintext = try JSONEncoder().encode([legacy])
        try? plaintext.write(to: Self.historyJSONURL())
        #expect(FileManager.default.fileExists(atPath: Self.historyJSONURL().path))

        let loaded = await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.toClipboardItem()?.plainText == "from before the upgrade")

        // Plaintext file must be gone, encrypted file must be present.
        #expect(!FileManager.default.fileExists(atPath: Self.historyJSONURL().path))
        #expect(FileManager.default.fileExists(atPath: Self.historyEncURL().path))

        await store.clear()
    }

    // MARK: - Image file storage

    @Test("Image payloads are stored encrypted outside history.enc and round-trip on load")
    func imagePayloadsAreStoredExternally() async {
        let store = makeStore()
        await store.clear()

        let pngData = Self.onePixelPNG()
        let item = ClipboardItem(
            content: .image(pngData, CGSize(width: 1, height: 1)),
            contentType: .image
        )
        let entry = StoredEntry(item: item)

        await store.save(entries: [entry])

        // The encrypted image file should exist next to history.enc.
        let imageURL = Self.encryptedImageURL(id: entry.id)
        #expect(FileManager.default.fileExists(atPath: imageURL.path))

        // And it should actually be encrypted — the PNG magic bytes should not be present.
        if let ciphertext = try? Data(contentsOf: imageURL) {
            let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            #expect(!ciphertext.prefix(4).elementsEqual(pngMagic))
        }

        // Loading round-trips the image data.
        let loaded = await store.load()
        #expect(loaded.first?.imageData == pngData)

        await store.clear()
    }

    @Test("Clearing the store removes image files from disk")
    func clearRemovesImageFiles() async {
        let store = makeStore()
        await store.clear()

        let item = ClipboardItem(
            content: .image(Self.onePixelPNG(), CGSize(width: 1, height: 1)),
            contentType: .image
        )
        await store.save(entries: [StoredEntry(item: item)])

        let imageURL = Self.encryptedImageURL(id: item.id)
        #expect(FileManager.default.fileExists(atPath: imageURL.path))

        await store.clear()
        #expect(!FileManager.default.fileExists(atPath: imageURL.path))
    }

    @Test("Orphaned image files are deleted on subsequent save")
    func orphanedImagesAreDeleted() async {
        let store = makeStore()
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

        let aURL = Self.encryptedImageURL(id: itemA.id)
        let bURL = Self.encryptedImageURL(id: itemB.id)
        #expect(FileManager.default.fileExists(atPath: aURL.path))
        #expect(FileManager.default.fileExists(atPath: bURL.path))

        // Save again without itemA — its image file must be removed.
        await store.save(entries: [StoredEntry(item: itemB)])
        #expect(!FileManager.default.fileExists(atPath: aURL.path))
        #expect(FileManager.default.fileExists(atPath: bURL.path))

        await store.clear()
    }

    @Test("Legacy plaintext image files are migrated to encrypted side files")
    func migratesLegacyImageFiles() async throws {
        let store = makeStore()
        await store.clear()

        // Hand-craft a legacy state: history.json references an item whose image is stored
        // as images/<uuid>.png (the pre-encryption layout).
        let pngData = Self.onePixelPNG()
        let item = ClipboardItem(
            content: .image(pngData, CGSize(width: 1, height: 1)),
            contentType: .image
        )
        let strippedEntry = StoredEntry(item: item).strippingImageData()
        let legacyJSON = try JSONEncoder().encode([strippedEntry])
        try? legacyJSON.write(to: Self.historyJSONURL())

        let legacyImageURL = Self.legacyPlaintextImageURL(id: item.id, ext: "png")
        try? pngData.write(to: legacyImageURL)
        #expect(FileManager.default.fileExists(atPath: legacyImageURL.path))

        let loaded = await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.imageData == pngData)

        // Plaintext image file is gone, encrypted version is present.
        #expect(!FileManager.default.fileExists(atPath: legacyImageURL.path))
        #expect(FileManager.default.fileExists(atPath: Self.encryptedImageURL(id: item.id).path))

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

    private static func historyEncURL() -> URL {
        appSupportDir().appendingPathComponent("history.enc")
    }

    private static func encryptedImageURL(id: UUID) -> URL {
        appSupportDir()
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).enc")
    }

    private static func legacyPlaintextImageURL(id: UUID, ext: String) -> URL {
        appSupportDir()
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).\(ext)")
    }
}
