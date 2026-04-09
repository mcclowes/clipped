import AppKit
@testable import Clipped
import Foundation
import Testing

@MainActor
struct ClipboardManagerTests {
    @Test("Starts with empty history")
    func emptyHistory() {
        let manager = ClipboardManager()
        manager.stopMonitoring()
        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.isEmpty)
    }

    @Test("Filter by content type returns matching items only")
    func filterByType() throws {
        let manager = ClipboardManager()
        manager.stopMonitoring()

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
        let manager = ClipboardManager()
        manager.stopMonitoring()

        let item1 = ClipboardItem(content: .text("hello world"), contentType: .plainText)
        let item2 = ClipboardItem(content: .text("goodbye"), contentType: .plainText)

        manager.items = [item1, item2]
        manager.searchQuery = "hello"

        #expect(manager.filteredItems.count == 1)
        #expect(manager.filteredItems.first?.preview.contains("hello") == true)
    }

    @Test("Toggle pin moves item between lists")
    func togglePin() {
        let manager = ClipboardManager()
        manager.stopMonitoring()

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
        let manager = ClipboardManager()
        manager.stopMonitoring()

        let item = ClipboardItem(content: .text("remove me"), contentType: .plainText)
        manager.items = [item]

        manager.removeItem(item)

        #expect(manager.items.isEmpty)
    }

    @Test("Clear all preserves pinned items by default")
    func clearAllPreservesPinned() {
        let manager = ClipboardManager()
        manager.stopMonitoring()

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
        let manager = ClipboardManager()
        manager.stopMonitoring()

        for i in 0...15 {
            manager.items.append(
                ClipboardItem(content: .text("item \(i)"), contentType: .plainText)
            )
        }

        #expect(manager.items.count == 16)

        manager.trimToMaxSize()

        #expect(manager.items.count == ClipboardManager.maxHistorySize)
        // First items should be preserved (they're at the front)
        #expect(manager.items.first?.preview == "item 0")
    }

    @Test("Trim to max size preserves pinned items")
    func trimPreservesPinned() {
        let manager = ClipboardManager()
        manager.stopMonitoring()

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

struct LinkMetadataFetcherTests {
    @Test("Parses title from HTML")
    @MainActor
    func parseTitle() async throws {
        let fetcher = LinkMetadataFetcher.shared
        // Test with a reliable public URL
        let title = try await fetcher.fetchTitle(for: #require(URL(string: "https://example.com")))
        #expect(title != nil)
        #expect(title?.contains("Example") == true)
    }

    @Test("Returns nil for non-HTTP URLs")
    @MainActor
    func nonHttpUrl() async throws {
        let fetcher = LinkMetadataFetcher.shared
        let title = try await fetcher.fetchTitle(for: #require(URL(string: "ftp://example.com")))
        #expect(title == nil)
    }
}
