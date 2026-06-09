import AppKit
@testable import Clipped
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@MainActor
struct ClipboardManagerTests {
    // swiftlint:disable large_tuple
    private func makeManager(persistHistory: Bool = true)
        -> (ClipboardManager, MockHistoryStore, MockSettingsManager, MockLinkMetadataFetcher)
    {
        // swiftlint:enable large_tuple
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
        manager.selectedFilter = .contentType(.plainText)

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
    func togglePin() async {
        let (manager, history, _, _) = makeManager()
        let item = ClipboardItem(content: .text("pin me"), contentType: .plainText)
        manager.items = [item]

        manager.togglePin(item)
        await manager.flushPendingSaves()

        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.count == 1)
        #expect(item.isPinned == true)
        #expect(await history.saveCallCount > 0)

        manager.togglePin(item)
        await manager.flushPendingSaves()

        #expect(manager.items.count == 1)
        #expect(manager.pinnedItems.isEmpty)
        #expect(item.isPinned == false)
    }

    @Test("Remove item removes from correct list")
    func removeItem() async {
        let (manager, history, _, _) = makeManager()
        let item = ClipboardItem(content: .text("remove me"), contentType: .plainText)
        manager.items = [item]

        manager.removeItem(item)
        await manager.flushPendingSaves()

        #expect(manager.items.isEmpty)
        #expect(await history.saveCallCount > 0)
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

    @Test("Clear all returns snapshot that can be restored in original order")
    func clearAllSnapshotRestoresOrder() {
        let (manager, _, _, _) = makeManager()

        let a = ClipboardItem(content: .text("a"), contentType: .plainText)
        let b = ClipboardItem(content: .text("b"), contentType: .plainText)
        let c = ClipboardItem(content: .text("c"), contentType: .plainText)
        let pinnedOne = ClipboardItem(content: .text("p1"), contentType: .plainText, isPinned: true)

        manager.items = [a, b, c]
        manager.pinnedItems = [pinnedOne]

        let snapshot = manager.clearAll()
        #expect(manager.items.isEmpty)

        manager.restore(snapshot)
        #expect(manager.items.map(\.preview) == ["a", "b", "c"])
        #expect(manager.pinnedItems.count == 1)
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
    func loadPersistedHistory() async {
        let (manager, history, settings, _) = makeManager()
        settings.persistAcrossReboots = true

        let item = ClipboardItem(content: .text("persisted"), contentType: .plainText)
        await history.setLoadResult([StoredEntry(item: item)])

        await manager.loadPersistedHistory()

        #expect(manager.items.count == 1)
        #expect(manager.items.first?.plainText == "persisted")
    }

    @Test("Load persisted history skipped when persistence disabled")
    func loadPersistedHistoryDisabled() async {
        let (manager, history, settings, _) = makeManager()
        settings.persistAcrossReboots = false

        let item = ClipboardItem(content: .text("persisted"), contentType: .plainText)
        await history.setLoadResult([StoredEntry(item: item)])

        await manager.loadPersistedHistory()

        #expect(manager.items.isEmpty)
    }

    @Test("Save history skipped when persistence disabled")
    func saveHistoryDisabled() async {
        let (manager, history, settings, _) = makeManager()
        settings.persistAcrossReboots = false

        manager.items = [ClipboardItem(content: .text("test"), contentType: .plainText)]
        manager.saveHistory()
        await manager.flushPendingSaves()

        #expect(await history.saveCallCount == 0)
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

    @Test("Filtered pinned items respects content type filter")
    func filteredPinnedByType() throws {
        let (manager, _, _, _) = makeManager()

        let textPinned = ClipboardItem(content: .text("pinned text"), contentType: .plainText)
        let urlPinned = try ClipboardItem(
            content: .url(#require(URL(string: "https://example.com"))),
            contentType: .url
        )

        manager.pinnedItems = [textPinned, urlPinned]
        manager.selectedFilter = .contentType(.url)

        #expect(manager.filteredPinnedItems.count == 1)
        #expect(manager.filteredPinnedItems.first?.contentType == .url)
    }

    @Test("Filtered pinned items respects search query")
    func filteredPinnedBySearch() {
        let (manager, _, _, _) = makeManager()

        let item1 = ClipboardItem(content: .text("hello world"), contentType: .plainText)
        let item2 = ClipboardItem(content: .text("goodbye"), contentType: .plainText)

        manager.pinnedItems = [item1, item2]
        manager.searchQuery = "hello"

        #expect(manager.filteredPinnedItems.count == 1)
        #expect(manager.filteredPinnedItems.first?.preview.contains("hello") == true)
    }

    @Test("Filtered pinned items returns all when no filter active")
    func filteredPinnedNoFilter() {
        let (manager, _, _, _) = makeManager()

        let item1 = ClipboardItem(content: .text("one"), contentType: .plainText)
        let item2 = ClipboardItem(content: .text("two"), contentType: .plainText)

        manager.pinnedItems = [item1, item2]

        #expect(manager.filteredPinnedItems.count == 2)
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

    @Test("Dev filter returns only developer content items")
    func devFilter() {
        let (manager, _, _, _) = makeManager()

        let devItem = ClipboardItem(
            content: .text("550e8400-e29b-41d4-a716-446655440000"),
            contentType: .plainText,
            isDeveloperContent: true
        )
        let normalItem = ClipboardItem(content: .text("hello world"), contentType: .plainText)
        let codeItem = ClipboardItem(
            content: .text("let x = 1"),
            contentType: .plainText,
            isDeveloperContent: true
        )

        manager.items = [devItem, normalItem, codeItem]
        manager.selectedFilter = .developer

        #expect(manager.filteredItems.count == 2)
        let allDev = manager.filteredItems.allSatisfy(\.isDeveloperContent)
        #expect(allDev)
    }

    @Test("Content category filter returns items tagged with that category")
    func categoryFilter() {
        let (manager, _, _, _) = makeManager()

        let emailItem = ClipboardItem(
            content: .text("ping alice@example.com"),
            contentType: .plainText,
            detectedCategories: [.email]
        )
        let phoneItem = ClipboardItem(
            content: .text("+1 415 555 0199"),
            contentType: .plainText,
            detectedCategories: [.phoneNumber]
        )
        let plain = ClipboardItem(content: .text("nothing here"), contentType: .plainText)

        manager.items = [emailItem, phoneItem, plain]

        manager.selectedFilter = .category(.email)
        #expect(manager.filteredItems.count == 1)
        #expect(manager.filteredItems.first?.detectedCategories.contains(.email) == true)

        manager.selectedFilter = .category(.phoneNumber)
        #expect(manager.filteredItems.count == 1)
        #expect(manager.filteredItems.first?.detectedCategories.contains(.phoneNumber) == true)
    }

    @Test("Source app filter returns items from apps in that category")
    func sourceAppFilter() {
        let (manager, _, _, _) = makeManager()

        let fromSafari = ClipboardItem(
            content: .text("browser text"),
            contentType: .plainText,
            sourceAppBundleID: "com.apple.Safari"
        )
        let fromXcode = ClipboardItem(
            content: .text("editor text"),
            contentType: .plainText,
            sourceAppBundleID: "com.apple.dt.Xcode"
        )
        let fromSlack = ClipboardItem(
            content: .text("chat text"),
            contentType: .plainText,
            sourceAppBundleID: "com.tinyspeck.slackmacgap"
        )

        manager.items = [fromSafari, fromXcode, fromSlack]

        manager.selectedFilter = .sourceApp(.browser)
        #expect(manager.filteredItems.count == 1)
        #expect(manager.filteredItems.first?.sourceAppBundleID == "com.apple.Safari")

        manager.selectedFilter = .sourceApp(.codeEditor)
        #expect(manager.filteredItems.count == 1)
        #expect(manager.filteredItems.first?.sourceAppBundleID == "com.apple.dt.Xcode")

        manager.selectedFilter = .sourceApp(.communication)
        #expect(manager.filteredItems.count == 1)
        #expect(manager.filteredItems.first?.sourceAppBundleID == "com.tinyspeck.slackmacgap")
    }

    @Test("Source app category is derived from bundle ID")
    func sourceAppCategoryDerived() {
        let item = ClipboardItem(
            content: .text("hello"),
            contentType: .plainText,
            sourceAppBundleID: "com.google.Chrome"
        )
        #expect(item.sourceAppCategory == .browser)
    }

    @Test("Trim to max size counts developer content against the cap")
    func trimCapsDevContent() {
        let (manager, _, settings, _) = makeManager()
        settings.maxHistorySize = 5

        // 8 developer-content items, none pinned: the cap must apply to them too,
        // otherwise auto-detected code grows the history without bound.
        for i in 0..<8 {
            manager.items.append(
                ClipboardItem(
                    content: .text("dev item \(i)"),
                    contentType: .plainText,
                    isDeveloperContent: true
                )
            )
        }

        manager.trimToMaxSize()

        #expect(manager.items.count == 5)
        let allDev = manager.items.allSatisfy(\.isDeveloperContent)
        #expect(allDev)
    }

    @Test("Trim to max size keeps newest and evicts oldest regardless of content type")
    func trimEvictsOldestMixed() {
        let (manager, _, settings, _) = makeManager()
        settings.maxHistorySize = 3

        // items[0] is newest (insert order matches `items` front-to-back).
        let newest = ClipboardItem(content: .text("newest"), contentType: .plainText)
        manager.items.append(newest)
        for i in 0..<5 {
            manager.items.append(
                ClipboardItem(
                    content: .text("dev \(i)"),
                    contentType: .plainText,
                    isDeveloperContent: true
                )
            )
        }

        manager.trimToMaxSize()

        #expect(manager.items.count == 3)
        #expect(manager.items.first?.id == newest.id)
    }

    // MARK: - Image utilities

    private static func pngImageItem(width: Int = 40, height: Int = 30) -> ClipboardItem {
        TestImageFactory.imageItem(width: width, height: height)
    }

    private static func imageData(of item: ClipboardItem) -> Data? {
        guard case let .image(data, _) = item.content else { return nil }
        return data
    }

    @Test("Compressing an image inserts a JPEG result as a new history item")
    func compressImageInsertsResult() throws {
        let (manager, _, _, _) = makeManager()
        let original = Self.pngImageItem()
        manager.items = [original]

        manager.compressImage(original)

        #expect(manager.items.count == 2)
        let result = try #require(manager.items.first)
        let data = try #require(Self.imageData(of: result))
        #expect(ImageProcessor.format(of: data) == .jpeg)
        #expect(result.mutationsApplied == ["Compressed"])
    }

    @Test("Converting an image emits a decodable result in the requested format")
    func convertImageFormat() throws {
        let (manager, _, _, _) = makeManager()
        let original = Self.pngImageItem()
        manager.items = [original]

        manager.convertImage(original, to: .heic)

        let result = try #require(manager.items.first)
        let data = try #require(Self.imageData(of: result))
        #expect(ImageProcessor.pixelSize(of: data) != nil)
        #expect(result.mutationsApplied == ["Converted to HEIC"])
    }

    @Test("Resizing an image halves its dimensions")
    func resizeImageHalves() throws {
        let (manager, _, _, _) = makeManager()
        let original = Self.pngImageItem(width: 80, height: 60)
        manager.items = [original]

        manager.resizeImage(original, scale: 0.5)

        let result = try #require(manager.items.first)
        let data = try #require(Self.imageData(of: result))
        let size = try #require(ImageProcessor.pixelSize(of: data))
        #expect(Int(size.width) == 40)
        #expect(result.mutationsApplied == ["Resized 50%"])
    }

    @Test("Image transforms are ignored for non-image items")
    func transformIgnoresNonImage() {
        let (manager, _, _, _) = makeManager()
        let textItem = ClipboardItem(content: .text("not an image"), contentType: .plainText)
        manager.items = [textItem]

        manager.compressImage(textItem)

        #expect(manager.items.count == 1)
    }

    @Test("exportData returns markdown bytes for a text item")
    func exportDataMarkdown() throws {
        let (manager, _, _, _) = makeManager()
        let item = ClipboardItem(content: .text("body text"), contentType: .plainText)
        let data = try #require(manager.exportData(for: item, format: .markdown))
        #expect(String(data: data, encoding: .utf8) == "body text")
    }
}
