import AppKit
@testable import Clipped
import Testing

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

    @Test("Converts italic text to Markdown")
    func italicConversion() {
        let attributed = NSMutableAttributedString(string: "hello italic world")
        let italicFont = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        attributed.addAttribute(.font, value: italicFont, range: NSRange(location: 6, length: 6))

        let markdown = MarkdownConverter.convert(attributedString: attributed)
        #expect(markdown.contains("*italic*"))
    }

    @Test("Converts bold+italic text to Markdown")
    func boldItalicConversion() {
        let attributed = NSMutableAttributedString(string: "hello mixed world")
        let font = NSFontManager.shared.convert(NSFont.boldSystemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        attributed.addAttribute(.font, value: font, range: NSRange(location: 6, length: 5))

        let markdown = MarkdownConverter.convert(attributedString: attributed)
        #expect(markdown.contains("***mixed***"))
    }

    @Test("Converts links to Markdown")
    func linkConversion() throws {
        let attributed = NSMutableAttributedString(string: "click here")
        let url = try #require(URL(string: "https://example.com"))
        attributed.addAttribute(.link, value: url, range: NSRange(location: 0, length: 10))

        let markdown = MarkdownConverter.convert(attributedString: attributed)
        #expect(markdown.contains("[click here](https://example.com)"))
    }

    @Test("Converts string URL links to Markdown")
    func stringLinkConversion() {
        let attributed = NSMutableAttributedString(string: "click here")
        attributed.addAttribute(.link, value: "https://example.com", range: NSRange(location: 0, length: 10))

        let markdown = MarkdownConverter.convert(attributedString: attributed)
        #expect(markdown.contains("[click here](https://example.com)"))
    }

    @Test("Returns nil for invalid RTF data")
    func invalidRtf() {
        let result = MarkdownConverter.convert(rtfData: Data([0x00, 0x01, 0x02]))
        #expect(result == nil)
    }

    @Test("Converts plain text without formatting")
    func plainText() {
        let attributed = NSAttributedString(string: "just plain text")
        let markdown = MarkdownConverter.convert(attributedString: attributed)
        #expect(markdown == "just plain text")
    }
}
