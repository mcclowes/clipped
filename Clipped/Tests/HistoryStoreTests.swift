@testable import Clipped
import CryptoKit
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct HistoryStoreTests {
    /// Per-suite temp directory so tests never read or delete the real app's
    /// `~/Library/Application Support/Clipped/` history.
    private let baseDir: URL

    init() {
        baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClippedHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore(
        keyStore: any KeychainKeyStoring = InMemoryKeyStore()
    ) -> HistoryStore {
        HistoryStore(keyStore: keyStore, baseDirectory: baseDir)
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

    @Test("Missing Application Support keeps history in memory")
    func missingApplicationSupport() async throws {
        let keyStore = InMemoryKeyStore()
        let store = HistoryStore.makeDefaultStore(applicationSupportDirectory: nil, keyStore: keyStore)
        #expect(await store.load().isEmpty)
        let first = makeEntry(text: "session only")
        let second = makeEntry(text: "pinned session item", isPinned: true)
        await store.save(entries: [first, second])
        #expect(await store.load().map(\.id) == [first.id, second.id])
        #expect(await store.retryLoad().map(\.id) == [first.id, second.id])
        #expect(await store.lastLoadError() == nil)
        #expect(try keyStore.loadKey() == nil)

        await store.save(entries: [second])
        #expect(await store.load().map(\.id) == [second.id])
        await store.clear()
        #expect(await store.load().isEmpty)
        await store.save(entries: [first])
        await store.startFresh()
        #expect(await store.load().isEmpty)
        #expect(try keyStore.loadKey() == nil)
    }

    @Test("Memory-only history does not survive a new store")
    func memoryOnlyHistoryIsSessionLocal() async throws {
        let keyStore = InMemoryKeyStore()
        let first = HistoryStore.makeDefaultStore(applicationSupportDirectory: nil, keyStore: keyStore)
        await first.save(entries: [makeEntry(text: "private fixture")])
        let second = HistoryStore.makeDefaultStore(applicationSupportDirectory: nil, keyStore: keyStore)
        #expect(await first.load().count == 1)
        #expect(await second.load().isEmpty)
        #expect(try keyStore.loadKey() == nil)
    }

    @Test("Available Application Support retains encrypted persistence")
    func availableApplicationSupport() async throws {
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let keyStore = InMemoryKeyStore()
        let store = HistoryStore.makeDefaultStore(applicationSupportDirectory: baseDir, keyStore: keyStore)
        let entry = makeEntry(text: "encrypted fixture")
        await store.save(entries: [entry])
        let appDirectory = baseDir.appendingPathComponent("Clipped", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: appDirectory.appendingPathComponent("history.enc").path))
        #expect(!FileManager.default.fileExists(atPath: appDirectory.appendingPathComponent("history.json").path))
        let attributes = try FileManager.default.attributesOfItem(atPath: appDirectory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let reloaded = HistoryStore.makeDefaultStore(applicationSupportDirectory: baseDir, keyStore: keyStore)
        #expect(await reloaded.load().map(\.id) == [entry.id])
        #expect(await reloaded.lastLoadError() == nil)
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

        let data = try? Data(contentsOf: historyEncURL())
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

        #expect(!FileManager.default.fileExists(atPath: historyJSONURL().path))
        #expect(FileManager.default.fileExists(atPath: historyEncURL().path))

        await store.clear()
    }

    @Test("A legacy history.json that fails to migrate survives a later save")
    func failedMigrationPreservesPlaintext() async throws {
        let store = makeStore()
        await store.clear()

        // Legacy plaintext that isn't decodable as [StoredEntry], so migration bails out and
        // deliberately leaves the file alone for manual recovery.
        let legacyURL = historyJSONURL()
        try Data(#"{"unexpected":"shape"}"#.utf8).write(to: legacyURL)

        _ = await store.load()
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))

        // The user copies something; the save that follows must not tidy away a file that
        // was never migrated — it's their only readable copy.
        await store.save(entries: [makeEntry(text: "new")])

        #expect(FileManager.default.fileExists(atPath: legacyURL.path))

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
        #expect(!FileManager.default.fileExists(atPath: historyEncURL().path))

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
        try? junk.write(to: historyEncURL())

        let loaded = await store.load()
        #expect(loaded.isEmpty)
        #expect(await store.lastLoadError() == .decryptionFailed)

        await store.clear()
    }

    @Test("Save is refused after a failed decrypt so recoverable ciphertext isn't overwritten")
    func saveRefusedAfterDecryptionFailure() async {
        let keyStore1 = InMemoryKeyStore()
        let store1 = makeStore(keyStore: keyStore1)
        await store1.clear()
        await store1.save(entries: [makeEntry(text: "original secret")])
        let originalCiphertext = try? Data(contentsOf: historyEncURL())

        // A new instance with a different key can't decrypt the file.
        let keyStore2 = InMemoryKeyStore()
        let store2 = makeStore(keyStore: keyStore2)
        _ = await store2.load()
        #expect(await store2.lastLoadError() == .decryptionFailed)

        // A save now (e.g. the user copies something) must NOT clobber the original ciphertext.
        await store2.save(entries: [makeEntry(text: "new item")])
        let afterCiphertext = try? Data(contentsOf: historyEncURL())
        #expect(afterCiphertext == originalCiphertext)

        // The original is still recoverable with the correct key.
        let recovered = makeStore(keyStore: keyStore1)
        let loaded = await recovered.load()
        #expect(loaded.first?.toClipboardItem()?.plainText == "original secret")

        await recovered.clear()
    }

    @Test("Rich-text representations and item metadata survive a save/load round-trip")
    func preservesRepresentationsAndItemMetadata() async {
        let store = makeStore()
        await store.clear()

        let item = ClipboardItem(content: .text("cleaned"), contentType: .plainText)
        item.originalContent = .text("original with tracking")
        item.mutationsApplied = ["Stripped tracking parameters"]
        item.customPasteboardTypes = ["com.example.custom": Data([1, 2, 3, 4])]
        item.htmlData = Data("<p>cleaned</p>".utf8)
        await store.save(entries: [StoredEntry(item: item)])

        let restored = await store.load().first?.toClipboardItem()
        #expect(restored?.customPasteboardTypes?["com.example.custom"] == Data([1, 2, 3, 4]))
        #expect(restored?.htmlData == Data("<p>cleaned</p>".utf8))
        if case let .text(str) = restored?.originalContent {
            #expect(str == "original with tracking")
        } else {
            Issue.record("originalContent did not round-trip")
        }

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
        try? plaintext.write(to: historyJSONURL())
        #expect(FileManager.default.fileExists(atPath: historyJSONURL().path))

        let loaded = await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.toClipboardItem()?.plainText == "from before the upgrade")

        // Plaintext file must be gone, encrypted file must be present.
        #expect(!FileManager.default.fileExists(atPath: historyJSONURL().path))
        #expect(FileManager.default.fileExists(atPath: historyEncURL().path))

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
        let imageURL = encryptedImageURL(id: entry.id)
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

        let imageURL = encryptedImageURL(id: item.id)
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

        let aURL = encryptedImageURL(id: itemA.id)
        let bURL = encryptedImageURL(id: itemB.id)
        #expect(FileManager.default.fileExists(atPath: aURL.path))
        #expect(FileManager.default.fileExists(atPath: bURL.path))

        // Save again without itemA — its image file must be removed.
        await store.save(entries: [StoredEntry(item: itemB)])
        #expect(!FileManager.default.fileExists(atPath: aURL.path))
        #expect(FileManager.default.fileExists(atPath: bURL.path))

        await store.clear()
    }

    @Test("A failed history save preserves images referenced by the previous history")
    func failedSavePreservesReferencedImages() async throws {
        let keyStore = InMemoryKeyStore()
        let store = makeStore(keyStore: keyStore)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let imageData = Self.onePixelPNG()
        let itemA = ClipboardItem(content: .image(imageData, CGSize(width: 1, height: 1)), contentType: .image)
        let itemB = ClipboardItem(content: .image(imageData, CGSize(width: 1, height: 1)), contentType: .image)
        let entryA = StoredEntry(item: itemA)
        let entryB = StoredEntry(item: itemB)
        await store.save(entries: [entryA, entryB])
        let originalHistory = try Data(contentsOf: historyEncURL())
        let originalImageA = try Data(contentsOf: encryptedImageURL(id: itemA.id))
        let initial = await store.load()
        try #require(initial.map(\.id) == [itemA.id, itemB.id])
        try #require(initial.allSatisfy { $0.imageData == imageData })

        let blockedURL = historyEncURL().appendingPathExtension("tmp")
        try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: false)
        try Data("block history write".utf8).write(to: blockedURL.appendingPathComponent("blocker"))
        await store.save(entries: [entryB])

        #expect(try Data(contentsOf: historyEncURL()) == originalHistory)
        #expect((try? Data(contentsOf: encryptedImageURL(id: itemA.id))) == originalImageA)
        let restartedStore = makeStore(keyStore: keyStore)
        let recovered = await restartedStore.load()
        #expect(recovered.map(\.id) == [itemA.id, itemB.id])
        #expect(recovered.map(\.imageData) == [imageData, imageData])

        try FileManager.default.removeItem(at: blockedURL)
        await restartedStore.save(entries: [entryB])
        #expect(FileManager.default.fileExists(atPath: encryptedImageURL(id: itemA.id).path) == false)
        #expect(await restartedStore.load().map(\.id) == [itemB.id])
        #expect(await restartedStore.load().first?.imageData == imageData)
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
        try? legacyJSON.write(to: historyJSONURL())

        let legacyImageURL = legacyPlaintextImageURL(id: item.id, ext: "png")
        try? pngData.write(to: legacyImageURL)
        #expect(FileManager.default.fileExists(atPath: legacyImageURL.path))

        let loaded = await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.imageData == pngData)

        // Plaintext image file is gone, encrypted version is present.
        #expect(!FileManager.default.fileExists(atPath: legacyImageURL.path))
        #expect(FileManager.default.fileExists(atPath: encryptedImageURL(id: item.id).path))

        await store.clear()
    }

    @Test("Failed image migration preserves the plaintext sidecar", arguments: ["png", "tiff"])
    func failedImageMigrationPreservesPlaintext(ext: String) async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let entry = try prepareBlockedImageMigration(ext: ext)
        let legacyURL = legacyPlaintextImageURL(id: entry.id, ext: ext)

        _ = await store.load()

        #expect((try? Data(contentsOf: legacyURL)) == Self.onePixelPNG())
    }

    @Test("A later load retries a failed image migration", arguments: ["png", "tiff"])
    func retriesFailedImageMigration(ext: String) async throws {
        let keyStore = InMemoryKeyStore()
        let store = makeStore(keyStore: keyStore)
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let entry = try prepareBlockedImageMigration(ext: ext)
        let legacyURL = legacyPlaintextImageURL(id: entry.id, ext: ext)

        _ = await store.load()
        try #require(FileManager.default.fileExists(atPath: historyEncURL().path))
        try #require(FileManager.default.fileExists(atPath: historyJSONURL().path) == false)
        try #require(FileManager.default.fileExists(atPath: legacyURL.path))
        try FileManager.default.removeItem(at: encryptedImageURL(id: entry.id).appendingPathExtension("tmp"))

        let restartedStore = makeStore(keyStore: keyStore)
        let recovered = await restartedStore.load()

        #expect(recovered.first?.id == entry.id)
        #expect(recovered.first?.imageData == Self.onePixelPNG())
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == false)
        let ciphertext = try #require(try? Data(contentsOf: encryptedImageURL(id: entry.id)))
        let crypto = try HistoryCrypto(key: keyStore.loadOrCreateKey())
        #expect(try crypto.decrypt(ciphertext) == Self.onePixelPNG())
    }

    @Test("Failed image migrations remain usable through saves", arguments: ["png", "tiff"])
    func failedImageMigrationSurvivesSaves(ext: String) async throws {
        let keyStore = InMemoryKeyStore()
        let store = makeStore(keyStore: keyStore)
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let entry = try prepareBlockedImageMigration(ext: ext)
        let legacyURL = legacyPlaintextImageURL(id: entry.id, ext: ext)

        let loaded = await store.load()
        #expect(loaded.first?.imageData == Self.onePixelPNG())
        await store.save(entries: loaded)
        #expect((try? Data(contentsOf: legacyURL)) == Self.onePixelPNG())

        let restartedStore = makeStore(keyStore: keyStore)
        let reloaded = await restartedStore.load()
        #expect(reloaded.first?.imageData == Self.onePixelPNG())

        try FileManager.default.removeItem(at: encryptedImageURL(id: entry.id).appendingPathExtension("tmp"))
        await restartedStore.save(entries: reloaded)

        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == false)
        let ciphertext = try #require(try? Data(contentsOf: encryptedImageURL(id: entry.id)))
        let crypto = try HistoryCrypto(key: keyStore.loadOrCreateKey())
        #expect(try crypto.decrypt(ciphertext) == Self.onePixelPNG())
        #expect(await restartedStore.load().first?.imageData == Self.onePixelPNG())
    }

    // MARK: - Fixtures

    private func prepareBlockedImageMigration(ext: String) throws -> StoredEntry {
        let imageData = Self.onePixelPNG()
        let item = ClipboardItem(
            content: .image(imageData, CGSize(width: 1, height: 1)),
            contentType: .image
        )
        let entry = StoredEntry(item: item).strippingImageData()
        try JSONEncoder().encode([entry]).write(to: historyJSONURL())
        let legacyURL = legacyPlaintextImageURL(id: item.id, ext: ext)
        try imageData.write(to: legacyURL)

        let blockedURL = encryptedImageURL(id: item.id).appendingPathExtension("tmp")
        try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: false)
        try Data("block temporary write".utf8).write(to: blockedURL.appendingPathComponent("blocker"))

        return entry
    }

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

    private func historyJSONURL() -> URL {
        baseDir.appendingPathComponent("history.json")
    }

    private func historyEncURL() -> URL {
        baseDir.appendingPathComponent("history.enc")
    }

    private func encryptedImageURL(id: UUID) -> URL {
        baseDir
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).enc")
    }

    private func legacyPlaintextImageURL(id: UUID, ext: String) -> URL {
        baseDir
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).\(ext)")
    }
}
