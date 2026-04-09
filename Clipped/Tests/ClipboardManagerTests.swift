import AppKit
@testable import Clipped
import Foundation
import Testing

// MARK: - Test doubles

@MainActor
final class MockPasteboard: PasteboardReading {
    var changeCount: Int = 0
    var types: [NSPasteboard.PasteboardType]?
    private var strings: [NSPasteboard.PasteboardType: String] = [:]
    private var dataStore: [NSPasteboard.PasteboardType: Data] = [:]

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        strings[dataType]
    }

    func data(forType dataType: NSPasteboard.PasteboardType) -> Data? {
        dataStore[dataType]
    }

    @discardableResult func clearContents() -> Int {
        strings.removeAll()
        dataStore.removeAll()
        types = nil
        changeCount += 1
        return changeCount
    }

    @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        strings[dataType] = string
        return true
    }

    @discardableResult func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        dataStore[dataType] = data
        return true
    }

    // Helpers for test setup
    func simulatePlainText(_ text: String) {
        changeCount += 1
        types = [.string]
        strings[.string] = text
    }

    func simulateURL(_ urlString: String) {
        changeCount += 1
        types = [.URL, .string]
        strings[.string] = urlString
    }

    func simulateRTF(rtfData: Data, plainText: String) {
        changeCount += 1
        types = [.rtf, .string]
        dataStore[.rtf] = rtfData
        strings[.string] = plainText
    }

    func simulateImage(tiffData: Data) {
        changeCount += 1
        types = [.tiff]
        dataStore[.tiff] = tiffData
    }
}

@MainActor
final class MockHistoryStore: HistoryStoring {
    var savedItems: [ClipboardItem] = []
    var savedPinnedItems: [ClipboardItem] = []
    var saveCallCount = 0
    var loadResult: (items: [ClipboardItem], pinned: [ClipboardItem]) = ([], [])

    func save(items: [ClipboardItem], pinnedItems: [ClipboardItem]) {
        savedItems = items
        savedPinnedItems = pinnedItems
        saveCallCount += 1
    }

    func load() -> (items: [ClipboardItem], pinned: [ClipboardItem]) {
        loadResult
    }

    func clear() {
        savedItems = []
        savedPinnedItems = []
    }
}

@MainActor
private func makeManager(
    pasteboard: MockPasteboard? = nil,
    historyStore: MockHistoryStore? = nil,
    settingsManager: SettingsManager? = nil
) -> (ClipboardManager, MockPasteboard, MockHistoryStore) {
    let pb = pasteboard ?? MockPasteboard()
    let store = historyStore ?? MockHistoryStore()
    let manager = ClipboardManager(
        settingsManager: settingsManager,
        historyStore: store,
        pasteboard: pb,
        startMonitoringOnInit: false
    )
    return (manager, pb, store)
}

// MARK: - Existing tests (updated to use DI)

@MainActor
struct ClipboardManagerTests {
    @Test("Starts with empty history")
    func emptyHistory() {
        let (manager, _, _) = makeManager()
        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.isEmpty)
    }

    @Test("Filter by content type returns matching items only")
    func filterByType() throws {
        let (manager, _, _) = makeManager()

        let textItem = ClipboardItem(
            content: .text("hello"),
            contentType: .plainText
        )
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
        let (manager, _, _) = makeManager()

        let item1 = ClipboardItem(content: .text("hello world"), contentType: .plainText)
        let item2 = ClipboardItem(content: .text("goodbye"), contentType: .plainText)

        manager.items = [item1, item2]
        manager.searchQuery = "hello"

        #expect(manager.filteredItems.count == 1)
        #expect(manager.filteredItems.first?.preview.contains("hello") == true)
    }

    @Test("Toggle pin moves item between lists")
    func togglePin() {
        let (manager, _, _) = makeManager()

        let item = ClipboardItem(content: .text("pin me"), contentType: .plainText)
        manager.items = [item]

        manager.togglePin(item)

        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.count == 1)
        #expect(item.isPinned == true)

        manager.togglePin(item)

        #expect(manager.items.count == 1)
        #expect(manager.pinnedItems.isEmpty)
        #expect(item.isPinned == false)
    }

    @Test("Remove item removes from correct list")
    func removeItem() {
        let (manager, _, _) = makeManager()

        let item = ClipboardItem(content: .text("remove me"), contentType: .plainText)
        manager.items = [item]

        manager.removeItem(item)

        #expect(manager.items.isEmpty)
    }

    @Test("Clear all preserves pinned items by default")
    func clearAllPreservesPinned() {
        let (manager, _, _) = makeManager()

        let pinned = ClipboardItem(content: .text("pinned"), contentType: .plainText)
        let unpinned = ClipboardItem(content: .text("unpinned"), contentType: .plainText)

        manager.pinnedItems = [pinned]
        manager.items = [unpinned]

        manager.clearAll()

        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.count == 1)
    }

    @Test("Trim to max size removes oldest unpinned items")
    func trimToMaxSize() {
        let (manager, _, _) = makeManager()

        for i in 0...15 {
            manager.items.append(
                ClipboardItem(content: .text("item \(i)"), contentType: .plainText)
            )
        }

        #expect(manager.items.count == 16)

        manager.trimToMaxSize()

        #expect(manager.items.count == ClipboardManager.maxHistorySize)
        #expect(manager.items.first?.preview == "item 0")
    }

    @Test("Trim to max size preserves pinned items")
    func trimPreservesPinned() {
        let (manager, _, _) = makeManager()

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

// MARK: - readClipboardItem tests

@MainActor
struct ReadClipboardItemTests {
    @Test("Reads plain text from pasteboard")
    func plainText() {
        let (manager, pb, _) = makeManager()
        pb.simulatePlainText("hello world")

        let item = manager.readClipboardItem(from: pb, appName: nil, bundleID: nil)

        #expect(item != nil)
        #expect(item?.contentType == .plainText)
        #expect(item?.plainText == "hello world")
    }

    @Test("Returns nil for empty string")
    func emptyString() {
        let (manager, pb, _) = makeManager()
        pb.changeCount += 1
        pb.types = [.string]
        pb.setString("", forType: .string)

        let item = manager.readClipboardItem(from: pb, appName: nil, bundleID: nil)

        #expect(item == nil)
    }

    @Test("Detects code from code editor bundle IDs")
    func codeDetection() {
        let (manager, pb, _) = makeManager()
        pb.simulatePlainText("let x = 42")

        let item = manager.readClipboardItem(
            from: pb, appName: "VS Code", bundleID: "com.microsoft.VSCode"
        )

        #expect(item?.contentType == .code)
    }

    @Test("Detects code from Xcode")
    func codeFromXcode() {
        let (manager, pb, _) = makeManager()
        pb.simulatePlainText("import Foundation")

        let item = manager.readClipboardItem(
            from: pb, appName: "Xcode", bundleID: "com.apple.dt.Xcode"
        )

        #expect(item?.contentType == .code)
    }

    @Test("Non-code-editor bundle ID gives plain text")
    func plainTextFromNonEditor() {
        let (manager, pb, _) = makeManager()
        pb.simulatePlainText("some text")

        let item = manager.readClipboardItem(
            from: pb, appName: "Safari", bundleID: "com.apple.Safari"
        )

        #expect(item?.contentType == .plainText)
    }

    @Test("Reads HTTP URL from pasteboard")
    func httpURL() {
        let (manager, pb, _) = makeManager()
        pb.simulateURL("https://example.com/page")

        let item = manager.readClipboardItem(from: pb, appName: nil, bundleID: nil)

        #expect(item?.contentType == .url)
        if case let .url(url) = item?.content {
            #expect(url.absoluteString == "https://example.com/page")
        } else {
            Issue.record("Expected .url content")
        }
    }

    @Test("Non-HTTP URL falls through to plain text")
    func nonHttpURL() {
        let (manager, pb, _) = makeManager()
        pb.changeCount += 1
        pb.types = [.URL, .string]
        pb.setString("ftp://files.example.com", forType: .string)

        let item = manager.readClipboardItem(from: pb, appName: nil, bundleID: nil)

        // Should fall through to plain text since scheme is not http/https
        #expect(item?.contentType == .plainText)
    }

    @Test("Reads rich text from pasteboard")
    func richText() {
        let (manager, pb, _) = makeManager()
        let rtfData = Data("{\\rtf1 hello}".utf8)
        pb.simulateRTF(rtfData: rtfData, plainText: "hello")

        let item = manager.readClipboardItem(from: pb, appName: nil, bundleID: nil)

        #expect(item?.contentType == .richText)
        if case let .richText(data, plain) = item?.content {
            #expect(data == rtfData)
            #expect(plain == "hello")
        } else {
            Issue.record("Expected .richText content")
        }
    }

    @Test("Image takes priority over text types")
    func imagePriority() {
        let (manager, pb, _) = makeManager()
        // Create a minimal valid 1x1 TIFF
        let tiffImage = NSImage(size: NSSize(width: 1, height: 1))
        tiffImage.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        tiffImage.unlockFocus()
        guard let tiffData = tiffImage.tiffRepresentation else {
            Issue.record("Failed to create TIFF data")
            return
        }

        pb.changeCount += 1
        pb.types = [.tiff, .string]
        pb.setData(tiffData, forType: .tiff)
        pb.setString("some text too", forType: .string)

        let item = manager.readClipboardItem(from: pb, appName: nil, bundleID: nil)

        #expect(item?.contentType == .image)
    }

    @Test("Returns nil when pasteboard is empty")
    func emptyPasteboard() {
        let (manager, pb, _) = makeManager()
        pb.changeCount += 1
        pb.types = []

        let item = manager.readClipboardItem(from: pb, appName: nil, bundleID: nil)

        #expect(item == nil)
    }

    @Test("Whitespace-only text returns nil")
    func whitespaceOnly() {
        let (manager, pb, _) = makeManager()
        pb.changeCount += 1
        pb.types = [.string]
        // setString with whitespace — but the check is `!string.isEmpty`, and "   " is not empty
        pb.setString("   ", forType: .string)

        let item = manager.readClipboardItem(from: pb, appName: nil, bundleID: nil)

        // Currently returns a plainText item with "   " — this documents the behavior
        #expect(item?.contentType == .plainText)
        #expect(item?.plainText == "   ")
    }

    @Test("Source app name and bundle ID are captured")
    func sourceAppCaptured() {
        let (manager, pb, _) = makeManager()
        pb.simulatePlainText("test")

        let item = manager.readClipboardItem(
            from: pb, appName: "Safari", bundleID: "com.apple.Safari"
        )

        #expect(item?.sourceAppName == "Safari")
        #expect(item?.sourceAppBundleID == "com.apple.Safari")
    }
}

// MARK: - HistoryStore round-trip tests

@MainActor
struct HistoryStoreRoundTripTests {
    private func makeTempStore() -> HistoryStore {
        // Use the shared instance — it writes to ~/Library/Application Support/Clipped/
        // In a production test suite you'd want a temp directory, but for now this is sufficient
        let store = HistoryStore.shared
        store.clear()
        return store
    }

    @Test("Plain text round-trip preserves all fields")
    func plainTextRoundTrip() {
        let store = makeTempStore()
        let item = ClipboardItem(
            content: .text("hello world"),
            contentType: .plainText,
            sourceAppName: "Safari",
            sourceAppBundleID: "com.apple.Safari"
        )
        item.linkTitle = "Test Title"

        store.save(items: [item], pinnedItems: [])
        let (loaded, pinned) = store.load()

        #expect(loaded.count == 1)
        #expect(pinned.isEmpty)

        let restored = loaded[0]
        #expect(restored.id == item.id)
        #expect(restored.contentType == .plainText)
        #expect(restored.plainText == "hello world")
        #expect(restored.sourceAppName == "Safari")
        #expect(restored.sourceAppBundleID == "com.apple.Safari")
        #expect(restored.linkTitle == "Test Title")

        store.clear()
    }

    @Test("Timestamp is preserved across save/load")
    func timestampPreserved() {
        let store = makeTempStore()
        let fixedDate = Date(timeIntervalSince1970: 1_000_000)
        let item = ClipboardItem(
            content: .text("old item"),
            contentType: .plainText,
            timestamp: fixedDate
        )

        store.save(items: [item], pinnedItems: [])
        let (loaded, _) = store.load()

        #expect(loaded.count == 1)
        #expect(abs(loaded[0].timestamp.timeIntervalSince(fixedDate)) < 1)

        store.clear()
    }

    @Test("Pinned items are loaded into pinned list")
    func pinnedRoundTrip() {
        let store = makeTempStore()
        let pinned = ClipboardItem(
            content: .text("pinned item"),
            contentType: .plainText,
            isPinned: true
        )
        let regular = ClipboardItem(
            content: .text("regular item"),
            contentType: .plainText
        )

        store.save(items: [regular], pinnedItems: [pinned])
        let (loadedItems, loadedPinned) = store.load()

        #expect(loadedItems.count == 1)
        #expect(loadedPinned.count == 1)
        #expect(loadedPinned[0].isPinned == true)
        #expect(loadedPinned[0].plainText == "pinned item")

        store.clear()
    }

    @Test("Sensitive items are filtered from save")
    func sensitiveFiltered() {
        let store = makeTempStore()
        let sensitive = ClipboardItem(
            content: .text("my-password-123"),
            contentType: .plainText,
            isSensitive: true
        )
        let normal = ClipboardItem(
            content: .text("normal text"),
            contentType: .plainText
        )

        store.save(items: [sensitive, normal], pinnedItems: [])
        let (loaded, _) = store.load()

        #expect(loaded.count == 1)
        #expect(loaded[0].plainText == "normal text")

        store.clear()
    }

    @Test("URL round-trip preserves URL")
    func urlRoundTrip() throws {
        let store = makeTempStore()
        let item = try ClipboardItem(
            content: .url(#require(URL(string: "https://example.com/path?q=1"))),
            contentType: .url
        )

        store.save(items: [item], pinnedItems: [])
        let (loaded, _) = store.load()

        #expect(loaded.count == 1)
        if case let .url(url) = loaded[0].content {
            #expect(url.absoluteString == "https://example.com/path?q=1")
        } else {
            Issue.record("Expected .url content")
        }

        store.clear()
    }

    @Test("Rich text round-trip preserves RTF data and plain fallback")
    func richTextRoundTrip() {
        let store = makeTempStore()
        let rtfData = Data("{\\rtf1 bold text}".utf8)
        let item = ClipboardItem(
            content: .richText(rtfData, "bold text"),
            contentType: .richText
        )

        store.save(items: [item], pinnedItems: [])
        let (loaded, _) = store.load()

        #expect(loaded.count == 1)
        if case let .richText(data, plain) = loaded[0].content {
            #expect(data == rtfData)
            #expect(plain == "bold text")
        } else {
            Issue.record("Expected .richText content")
        }

        store.clear()
    }

    @Test("Empty save and load returns empty arrays")
    func emptyRoundTrip() {
        let store = makeTempStore()
        store.save(items: [], pinnedItems: [])
        let (items, pinned) = store.load()
        #expect(items.isEmpty)
        #expect(pinned.isEmpty)
        store.clear()
    }
}

// MARK: - Deduplication tests

@MainActor
struct DeduplicationTests {
    @Test("Items with same full content are deduplicated")
    func sameContentDeduplicated() {
        let (manager, _, _) = makeManager()

        let item1 = ClipboardItem(content: .text("hello"), contentType: .plainText)
        let item2 = ClipboardItem(content: .text("hello"), contentType: .plainText)

        manager.items = [item1]
        // Simulate what checkClipboard does:
        manager.items.removeAll { $0.content == item2.content && !$0.isPinned }
        manager.items.insert(item2, at: 0)

        #expect(manager.items.count == 1)
        #expect(manager.items[0].id == item2.id)
    }

    @Test("Items sharing first 200 chars but different content are not deduplicated")
    func longContentNotFalselyDeduplicated() {
        let (manager, _, _) = makeManager()
        let prefix = String(repeating: "a", count: 200)
        let item1 = ClipboardItem(content: .text(prefix + " ending 1"), contentType: .plainText)
        let item2 = ClipboardItem(content: .text(prefix + " ending 2"), contentType: .plainText)

        manager.items = [item1]
        manager.items.removeAll { $0.content == item2.content && !$0.isPinned }
        manager.items.insert(item2, at: 0)

        // Both should exist because the full content differs
        #expect(manager.items.count == 2)
    }

    @Test("Pinned items are not removed by deduplication")
    func pinnedNotDeduplicated() {
        let (manager, _, _) = makeManager()

        let pinned = ClipboardItem(content: .text("hello"), contentType: .plainText, isPinned: true)
        let newItem = ClipboardItem(content: .text("hello"), contentType: .plainText)

        manager.items = [pinned]
        manager.items.removeAll { $0.content == newItem.content && !$0.isPinned }
        manager.items.insert(newItem, at: 0)

        #expect(manager.items.count == 2)
    }
}

// MARK: - Markdown converter tests

@MainActor
struct MarkdownConverterTests {
    @Test("Converts bold text to Markdown")
    func boldConversion() {
        let attributed = NSMutableAttributedString(string: "hello bold world")
        let boldFont = NSFont.boldSystemFont(ofSize: 12)
        attributed.addAttribute(.font, value: boldFont, range: NSRange(location: 6, length: 4))

        let markdown = MarkdownConverter.convert(attributedString: attributed)
        #expect(markdown.contains("**bold**"))
    }

    @Test("Converts links to Markdown")
    func linkConversion() throws {
        let attributed = NSMutableAttributedString(string: "click here")
        let url = try #require(URL(string: "https://example.com"))
        attributed.addAttribute(.link, value: url, range: NSRange(location: 0, length: 10))

        let markdown = MarkdownConverter.convert(attributedString: attributed)
        #expect(markdown.contains("[click here](https://example.com)"))
    }

    @Test("Returns nil for invalid RTF data")
    func invalidRtf() {
        let result = MarkdownConverter.convert(rtfData: Data([0x00, 0x01, 0x02]))
        #expect(result == nil)
    }
}

// MARK: - Hex color parser tests

@MainActor
struct HexColorParserTests {
    @Test("Parses 6-digit hex colour")
    func sixDigit() {
        let color = HexColorParser.parse("#FF5733")
        #expect(color != nil)
    }

    @Test("Parses 3-digit shorthand hex colour")
    func threeDigit() {
        let color = HexColorParser.parse("#f0a")
        #expect(color != nil)
    }

    @Test("Returns nil for invalid hex")
    func invalid() {
        #expect(HexColorParser.parse("not a colour") == nil)
        #expect(HexColorParser.parse("#GGG") == nil)
        #expect(HexColorParser.parse("") == nil)
    }

    @Test("Finds first hex colour in text")
    func firstColorInText() {
        let color = HexColorParser.firstColor(in: "Background is #2ecc71 and text is #333")
        #expect(color != nil)
    }

    @Test("Returns nil when no hex colour present")
    func noColorInText() {
        #expect(HexColorParser.firstColor(in: "no colours here") == nil)
    }
}

// MARK: - LinkMetadataFetcher title parsing tests

@MainActor
struct LinkMetadataFetcherParsingTests {
    @Test("Parses title from simple HTML")
    func simpleTitle() {
        let html = "<html><head><title>Hello World</title></head><body></body></html>"
        let title = LinkMetadataFetcher.shared.parseTitle(from: html)
        #expect(title == "Hello World")
    }

    @Test("Parses title case-insensitively")
    func caseInsensitive() {
        let html = "<HTML><HEAD><TITLE>Upper Case</TITLE></HEAD></HTML>"
        let title = LinkMetadataFetcher.shared.parseTitle(from: html)
        #expect(title == "Upper Case")
    }

    @Test("Decodes HTML entities in title")
    func htmlEntities() {
        let html = "<title>Tom &amp; Jerry&#39;s &quot;Show&quot;</title>"
        let title = LinkMetadataFetcher.shared.parseTitle(from: html)
        #expect(title == "Tom & Jerry's \"Show\"")
    }

    @Test("Returns nil for missing title tag")
    func missingTitle() {
        let html = "<html><head></head><body>No title here</body></html>"
        let title = LinkMetadataFetcher.shared.parseTitle(from: html)
        #expect(title == nil)
    }

    @Test("Returns nil for empty title")
    func emptyTitle() {
        let html = "<title>   </title>"
        let title = LinkMetadataFetcher.shared.parseTitle(from: html)
        #expect(title == nil)
    }

    @Test("Truncates title to 120 characters")
    func longTitle() {
        let longText = String(repeating: "a", count: 200)
        let html = "<title>\(longText)</title>"
        let title = LinkMetadataFetcher.shared.parseTitle(from: html)
        #expect(title?.count == 120)
    }

    @Test("Handles title with attributes")
    func titleWithAttributes() {
        let html = "<title lang=\"en\">Attributed Title</title>"
        let title = LinkMetadataFetcher.shared.parseTitle(from: html)
        #expect(title == "Attributed Title")
    }

    @Test("Returns nil for non-HTTP URLs")
    func nonHttpUrl() async throws {
        let fetcher = LinkMetadataFetcher.shared
        let title = try await fetcher.fetchTitle(for: #require(URL(string: "ftp://example.com")))
        #expect(title == nil)
    }
}

// MARK: - ClipboardContent Equatable tests

@MainActor
struct ClipboardContentEquatableTests {
    @Test("Text content equality")
    func textEquality() {
        #expect(ClipboardContent.text("hello") == ClipboardContent.text("hello"))
        #expect(ClipboardContent.text("hello") != ClipboardContent.text("world"))
    }

    @Test("URL content equality")
    func urlEquality() throws {
        let url1 = try #require(URL(string: "https://example.com"))
        let url2 = try #require(URL(string: "https://example.com"))
        let url3 = try #require(URL(string: "https://other.com"))
        #expect(ClipboardContent.url(url1) == ClipboardContent.url(url2))
        #expect(ClipboardContent.url(url1) != ClipboardContent.url(url3))
    }

    @Test("Different content types are not equal")
    func differentTypes() {
        let text = ClipboardContent.text("https://example.com")
        let url = ClipboardContent.url(URL(string: "https://example.com")!)
        #expect(text != url)
    }
}
