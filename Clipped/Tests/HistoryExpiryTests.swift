@testable import Clipped
import Foundation
import Testing

@MainActor
struct HistoryExpiryTests {
    private func makeHistory(retention: HistoryRetention) -> (ClipboardHistory, MockSettingsManager) {
        let history = ClipboardHistory()
        let settings = MockSettingsManager()
        settings.historyRetention = retention
        history.settingsManager = settings
        return (history, settings)
    }

    private func textItem(_ string: String, ageDays: Double, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(
            content: .text(string),
            contentType: .plainText,
            timestamp: Date().addingTimeInterval(-ageDays * 24 * 60 * 60),
            isPinned: pinned
        )
    }

    // MARK: - HistoryRetention

    @Test("`.never` reports no expiry interval so expiry stays disabled")
    func neverDisablesExpiry() {
        #expect(HistoryRetention.never.interval == nil)
    }

    @Test("Other cases report the expected number of seconds")
    func intervalValues() {
        let day: TimeInterval = 86400
        #expect(HistoryRetention.oneDay.interval == day)
        #expect(HistoryRetention.sevenDays.interval == 7 * day)
        #expect(HistoryRetention.thirtyDays.interval == 30 * day)
        #expect(HistoryRetention.ninetyDays.interval == 90 * day)
    }

    // MARK: - trimExpiredItems

    @Test("Items older than retention are evicted, fresh items survive")
    func evictsOldItems() {
        let (history, _) = makeHistory(retention: .sevenDays)
        history.items = [
            textItem("fresh", ageDays: 1),
            textItem("stale", ageDays: 10),
        ]

        history.trimExpiredItems()

        #expect(history.items.map(\.preview) == ["fresh"])
    }

    @Test("Pinned items are exempt from expiry")
    func pinnedAreExempt() {
        let (history, _) = makeHistory(retention: .oneDay)
        let pinned = textItem("kept", ageDays: 30, pinned: true)
        history.pinnedItems = [pinned]
        history.items = [textItem("dropped", ageDays: 30)]

        history.trimExpiredItems()

        #expect(history.items.isEmpty)
        #expect(history.pinnedItems.count == 1)
    }

    @Test("`.never` retention is a no-op even with very old items")
    func neverIsNoOp() {
        let (history, _) = makeHistory(retention: .never)
        history.items = [textItem("ancient", ageDays: 365)]

        history.trimExpiredItems()

        #expect(history.items.count == 1)
    }

    @Test("Items right at the boundary are evicted")
    func boundary() {
        let (history, _) = makeHistory(retention: .oneDay)
        let now = Date()
        // Two seconds beyond the 1-day cutoff — must be removed.
        let stale = ClipboardItem(
            content: .text("stale"),
            contentType: .plainText,
            timestamp: now.addingTimeInterval(-86400 - 2)
        )
        history.items = [stale]

        history.trimExpiredItems(now: now)

        #expect(history.items.isEmpty)
    }
}

@MainActor
struct ClipboardRecopyPipelineTests {
    private struct Rig {
        let manager: ClipboardManager
        let store: MockHistoryStore
        let settings: MockSettingsManager
    }

    private actor PausedEnrichment: LinkMetadataFetching {
        private(set) var requests = 0
        private var pending: [CheckedContinuation<String?, Never>] = []
        private var finished = false
        private let started = AsyncStream<Void>.makeStream()

        func extract(_: Data) async -> String? {
            requests += 1
            guard !finished else { return "Recognized text" }
            return await withCheckedContinuation {
                pending.append($0)
                started.continuation.yield()
            }
        }

        func fetchMetadata(for _: URL) async -> LinkMetadata {
            let title = await extract(Data())
            return LinkMetadata(title: title, favicon: nil)
        }

        func waitUntilRequested() async {
            guard requests == 0 else { return }
            for await _ in started.stream {
                break
            }
        }

        func finish() {
            finished = true
            for continuation in pending {
                continuation.resume(returning: "Recognized text")
            }
            pending.removeAll()
        }
    }

    private func makeRig() -> Rig {
        let manager = ClipboardManager(pasteboard: MockPasteboard())
        let store = MockHistoryStore()
        let settings = MockSettingsManager()
        settings.persistAcrossReboots = true
        manager.historyStore = store
        manager.settingsManager = settings
        manager.linkMetadataFetcher = MockLinkMetadataFetcher()
        return Rig(manager: manager, store: store, settings: settings)
    }

    private func event(_ item: ClipboardItem, concealed: Bool = false) -> PasteboardMonitor.NewItemEvent {
        .init(item: item, bundleID: item.sourceAppBundleID, hasConcealedType: concealed)
    }

    @Test("Re-copy metadata failures preserve the retained URL enrichment", .bug(id: 118))
    func missingURLMetadataKeepsEnrichment() async throws {
        let rig = makeRig()
        await rig.manager.loadPersistedHistory()
        let url = try #require(URL(string: "https://example.invalid/recopy"))
        let first = ClipboardItem(content: .url(url), contentType: .url)
        first.linkTitle = "Known title"
        first.linkFavicon = Data([1, 2, 3])
        rig.manager.items = [first]

        #expect(rig.manager.ingest(event(ClipboardItem(content: .url(url), contentType: .url))))
        await rig.manager.awaitPendingEnrichments()
        await rig.manager.flushPendingSaves()

        #expect(rig.manager.items.first === first)
        #expect(first.linkTitle == "Known title")
        #expect(first.linkFavicon == Data([1, 2, 3]))
        #expect(await rig.store.savedEntries.map(\.id) == [first.id])
    }

    @Test(
        "Re-copying shares pending enrichment and saves the retained identity",
        .bug(id: 118),
        arguments: [false, true]
    )
    func recopySharesPendingEnrichment(isImage: Bool) async throws {
        let rig = makeRig()
        await rig.manager.loadPersistedHistory()
        let extractor = PausedEnrichment()
        rig.manager.extractImageText = { await extractor.extract($0) }
        rig.manager.linkMetadataFetcher = extractor
        let content: ClipboardContent = if isImage {
            .image(Data([1, 2, 3]), CGSize(width: 10, height: 10))
        } else {
            try .url(#require(URL(string: "https://example.invalid/pending")))
        }
        let type: ContentType = isImage ? .image : .url
        let first = ClipboardItem(content: content, contentType: type)
        #expect(rig.manager.ingest(event(first)))
        await extractor.waitUntilRequested()
        #expect(rig.manager.ingest(event(ClipboardItem(content: content, contentType: type))))
        let observing = AsyncStream<Void>.makeStream()
        let drain = Task {
            observing.continuation.yield()
            await rig.manager.awaitPendingEnrichment(for: first.id)
        }
        for await _ in observing.stream {
            break
        }

        await extractor.finish()
        await drain.value
        await rig.manager.flushPendingSaves()

        let requests = await extractor.requests
        #expect(requests == 1)
        #expect(rig.manager.items.first === first)
        if isImage {
            #expect(first.extractedText == "Recognized text")
        } else {
            #expect(first.linkTitle == "Recognized text")
        }
        #expect(first.isAwaitingImageText == false)
        #expect(await rig.store.savedEntries.map(\.id) == [first.id])
    }

    @Test("A secure re-copy replaces the prior expiry timer", .bug(id: 118), .timeLimit(.minutes(1)))
    func recopyRenewsSecureExpiry() async {
        let rig = makeRig()
        rig.manager.secureRemovalDelay = { _ in .seconds(3) }
        let first = ClipboardItem(content: .text("Private value"), contentType: .plainText)
        #expect(rig.manager.ingest(event(first, concealed: true)))
        let observing = AsyncStream<Void>.makeStream()
        let firstExpiry = Task {
            observing.continuation.yield()
            await rig.manager.awaitPendingSecureRemovals()
        }
        for await _ in observing.stream {
            break
        }
        rig.manager.secureRemovalDelay = { _ in .seconds(5) }

        #expect(rig.manager.ingest(event(
            ClipboardItem(content: first.content, contentType: .plainText), concealed: true
        )))
        await firstExpiry.value

        #expect(rig.manager.items.first === first)
        rig.manager.secureRemovalDelay = { _ in .zero }
        #expect(rig.manager.ingest(event(
            ClipboardItem(content: first.content, contentType: .plainText), concealed: true
        )))
        await rig.manager.awaitPendingSecureRemovals()
        #expect(rig.manager.items.isEmpty)
    }

    @Test("Generated secret re-copies expire the retained item", .bug(id: 118))
    func generatedTextUsesRetainedIdentity() async throws {
        let rig = makeRig()
        rig.settings.secretHandling = .treatLikePasswords
        rig.manager.secureRemovalDelay = { _ in .zero }
        rig.manager.authenticateSecretAccess = { _, completion in completion(false) }
        let secret = "sk_" + "test_EXAMPLEabcdefghij0123456789"
        let first = ClipboardItem(content: .text(secret), contentType: .plainText)
        try #require(first.containsSecret)
        rig.manager.items = [first]

        rig.manager.copyText(secret)
        try #require(rig.manager.items.first === first)
        await rig.manager.awaitPendingSecureRemovals()
        await rig.manager.flushPendingSaves()

        #expect(rig.manager.items.isEmpty)
        #expect(await rig.store.savedEntries.isEmpty)
    }
}

@MainActor
struct ClipboardHistoryInsertTests {
    private func makeHistory() -> ClipboardHistory {
        let history = ClipboardHistory()
        // persistAcrossReboots defaults false, so nothing touches disk.
        history.settingsManager = MockSettingsManager()
        return history
    }

    private func textItem(_ string: String) -> ClipboardItem {
        ClipboardItem(content: .text(string), contentType: .plainText)
    }

    @Test("Re-inserting identical content keeps one entry and moves it to the top")
    func dedupesIdenticalContent() {
        let history = makeHistory()
        #expect(history.insert(textItem("a")) != nil)
        #expect(history.insert(textItem("b")) != nil)
        #expect(history.insert(textItem("a")) != nil)
        #expect(history.items.map(\.preview) == ["a", "b"])
    }

    @Test("Re-copying content that is already pinned does not create a duplicate unpinned row")
    func skipsDuplicateOfPinned() {
        let history = makeHistory()
        let pinned = textItem("shared")
        pinned.isPinned = true
        history.pinnedItems = [pinned]

        #expect(history.insert(textItem("shared")) == nil)

        #expect(history.items.isEmpty)
        #expect(history.pinnedItems.count == 1)
    }

    @Test("Re-copying a URL preserves the previously-fetched link metadata")
    func preservesEnrichedMetadataOnRecopy() throws {
        let history = makeHistory()
        let url = try #require(URL(string: "https://example.com"))
        let first = ClipboardItem(content: .url(url), contentType: .url)
        first.linkTitle = "Example Domain"
        history.insert(first)

        // A fresh copy of the same URL arrives with no metadata yet.
        history.insert(ClipboardItem(content: .url(url), contentType: .url))

        #expect(history.items.count == 1)
        #expect(history.items.first?.linkTitle == "Example Domain")
    }

    @Test("Re-copying retains identity, restoration, and enriched representations", .bug(id: 118))
    func recopyRetainsIdentityAndEnrichment() throws {
        let history = makeHistory()
        let original = textItem("value")
        original.originalContent = .text(" value ")
        original.mutationsApplied = ["Trim whitespace"]
        original.detectedCategories = [.email]
        original.customPasteboardTypes = ["app.example.custom": Data([1, 2, 3])]
        original.htmlData = Data("<b>value</b>".utf8)
        history.items = [textItem("other"), original]

        history.insert(textItem("value"))

        let retained = try #require(history.items.first)
        #expect(retained === original)
        #expect(retained.id == original.id)
        #expect(retained.originalContent == original.originalContent)
        #expect(retained.mutationsApplied == original.mutationsApplied)
        #expect(retained.detectedCategories == original.detectedCategories)
        #expect(retained.customPasteboardTypes == original.customPasteboardTypes)
        #expect(retained.htmlData == original.htmlData)
        #expect(history.items.map(\.preview) == ["value", "other"])
    }

    @Test("Re-copying merges fresh metadata and refreshes capture details", .bug(id: 118))
    func recopyMergesFreshMetadata() throws {
        let history = makeHistory()
        let first = ClipboardItem(
            content: .text("value"), contentType: .plainText,
            sourceAppName: "Old app", sourceAppBundleID: "app.example.old",
            timestamp: Date(timeIntervalSince1970: 100), containsSecret: true, isDeveloperContent: true,
            detectedCategories: [.email]
        )
        first.linkFavicon = Data([1])
        first.customPasteboardTypes = ["retained": Data([2]), "updated": Data([3])]
        let incoming = ClipboardItem(
            content: .text("value"), contentType: .plainText,
            sourceAppName: "New app", sourceAppBundleID: "app.example.new",
            timestamp: Date(timeIntervalSince1970: 200), isSensitive: true,
            detectedCategories: [.phoneNumber]
        )
        incoming.linkTitle = "New title"
        incoming.htmlData = Data("<b>value</b>".utf8)
        incoming.customPasteboardTypes = ["updated": Data([4]), "added": Data([5])]
        incoming.originalContent = .text(" value ")
        incoming.mutationsApplied = ["Trim whitespace"]
        history.items = [first]

        let retained = try #require(history.insert(incoming))

        #expect(retained === first)
        #expect(retained.timestamp == incoming.timestamp)
        #expect(retained.sourceAppName == incoming.sourceAppName)
        #expect(retained.sourceAppBundleID == incoming.sourceAppBundleID)
        #expect(retained.linkTitle == incoming.linkTitle)
        #expect(retained.linkFavicon == Data([1]))
        #expect(retained.htmlData == incoming.htmlData)
        #expect(retained.customPasteboardTypes == ["retained": Data([2]), "updated": Data([4]), "added": Data([5])])
        #expect(retained.originalContent == incoming.originalContent)
        #expect(retained.mutationsApplied == incoming.mutationsApplied)
        #expect(retained.detectedCategories == [.email, .phoneNumber])
        #expect(retained.isSensitive && retained.containsSecret && retained.isDeveloperContent)
    }

    @Test("A bare re-copy cannot clear known privacy or pending-OCR flags", .bug(id: 118))
    func recopyKeepsPrivacyFlags() throws {
        let history = makeHistory()
        let first = textItem("value")
        first.isSensitive = true
        first.containsSecret = true
        first.isAwaitingImageText = true
        history.items = [first]

        let retained = try #require(history.insert(textItem("value")))

        #expect(retained.isSensitive && retained.containsSecret && retained.isAwaitingImageText)
    }

    @Test("An image re-copy keeps its encrypted sidecar path and persisted identity", .bug(id: 118))
    func recopyKeepsImageSidecar() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipped-recopy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(keyStore: InMemoryKeyStore(), baseDirectory: directory)
        let history = makeHistory()
        let payload = Data([1, 2, 3])
        let content = ClipboardContent.image(payload, CGSize(width: 10, height: 10))
        let first = ClipboardItem(content: content, contentType: .image)
        history.items = [first]
        await store.save(entries: [StoredEntry(item: first)])
        let images = directory.appendingPathComponent("images")
        let originalNames = try FileManager.default.contentsOfDirectory(atPath: images.path)
        try #require(originalNames == ["\(first.id.uuidString).enc"])

        let retained = try #require(history.insert(ClipboardItem(content: content, contentType: .image)))
        await store.save(entries: [StoredEntry(item: retained)])
        let loaded = await store.load()

        #expect(loaded.map(\.id) == [first.id])
        #expect(loaded.first?.imageData == payload)
        #expect(try FileManager.default.contentsOfDirectory(atPath: images.path) == originalNames)
    }
}
