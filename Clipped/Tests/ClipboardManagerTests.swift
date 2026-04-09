import AppKit
import Foundation
import Testing
@testable import Clipped

@MainActor
@Suite("ClipboardManager")
struct ClipboardManagerTests {
    @Test("Starts with empty history")
    func emptyHistory() {
        let manager = ClipboardManager()
        manager.stopMonitoring()
        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.isEmpty)
    }

    @Test("Filter by content type returns matching items only")
    func filterByType() {
        let manager = ClipboardManager()
        manager.stopMonitoring()

        let textItem = ClipboardItem(
            content: .text("hello"),
            contentType: .plainText
        )
        let urlItem = ClipboardItem(
            content: .url(URL(string: "https://example.com")!),
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

    @Test("Content type detection")
    func contentTypes() {
        let textItem = ClipboardItem(content: .text("plain"), contentType: .plainText)
        #expect(textItem.contentType == .plainText)
        #expect(textItem.plainText == "plain")

        let urlItem = ClipboardItem(
            content: .url(URL(string: "https://example.com")!),
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
    func linkTitle() {
        let urlItem = ClipboardItem(
            content: .url(URL(string: "https://example.com")!),
            contentType: .url
        )
        #expect(urlItem.linkTitle == nil)

        urlItem.linkTitle = "Example Domain"
        #expect(urlItem.linkTitle == "Example Domain")
    }
}

@MainActor
@Suite("MarkdownConverter")
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
    func linkConversion() {
        let attributed = NSMutableAttributedString(string: "click here")
        let url = URL(string: "https://example.com")!
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
@Suite("HexColorParser")
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

@Suite("LinkMetadataFetcher")
struct LinkMetadataFetcherTests {
    @Test("Parses title from HTML")
    @MainActor
    func parseTitle() async {
        let fetcher = LinkMetadataFetcher.shared
        // Test with a reliable public URL
        let title = await fetcher.fetchTitle(for: URL(string: "https://example.com")!)
        #expect(title != nil)
        #expect(title?.contains("Example") == true)
    }

    @Test("Returns nil for non-HTTP URLs")
    @MainActor
    func nonHttpUrl() async {
        let fetcher = LinkMetadataFetcher.shared
        let title = await fetcher.fetchTitle(for: URL(string: "ftp://example.com")!)
        #expect(title == nil)
    }
}
