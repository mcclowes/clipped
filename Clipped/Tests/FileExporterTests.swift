import AppKit
@testable import Clipped
import Foundation
import Testing
import UniformTypeIdentifiers

@MainActor
struct FileExporterTests {
    private static func richTextItem(_ string: String = "Hello world") -> ClipboardItem {
        let attributed = NSAttributedString(
            string: string,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]
        )
        let rtf = attributed
            .rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]) ?? Data()
        return ClipboardItem(content: .richText(rtf, string), contentType: .richText)
    }

    private static func pngItem(width: Int = 20, height: Int = 20) -> ClipboardItem {
        TestImageFactory.imageItem(width: width, height: height)
    }

    @Test("Text items can export to markdown and plain text")
    func textFormats() {
        let item = ClipboardItem(content: .text("just text"), contentType: .plainText)
        #expect(FileExporter.availableFormats(for: item) == [.markdown, .plainText])
    }

    @Test("Image items export to raster formats only")
    func imageFormats() {
        #expect(FileExporter.availableFormats(for: Self.pngItem()) == [.png, .jpeg, .heic])
    }

    @Test("Plain text from a web clipping is written verbatim as markdown")
    func plainTextMarkdown() throws {
        let item = ClipboardItem(content: .text("# Heading\n\nbody"), contentType: .plainText)
        let data = try FileExporter.data(for: item, format: .markdown)
        #expect(String(data: data, encoding: .utf8) == "# Heading\n\nbody")
    }

    @Test("Rich text converts to markdown with emphasis markers")
    func richTextToMarkdown() throws {
        let data = try FileExporter.data(for: Self.richTextItem("Bold"), format: .markdown)
        let markdown = try #require(String(data: data, encoding: .utf8))
        #expect(markdown.contains("**Bold**"))
    }

    @Test("Rich text exports the original RTF bytes")
    func richTextToRTF() throws {
        let item = Self.richTextItem()
        let data = try FileExporter.data(for: item, format: .richText)
        #expect(NSAttributedString(rtf: data, documentAttributes: nil) != nil)
    }

    @Test("Rich text exports valid HTML")
    func richTextToHTML() throws {
        let data = try FileExporter.data(for: Self.richTextItem("Hi"), format: .html)
        let html = try #require(String(data: data, encoding: .utf8))
        #expect(html.localizedCaseInsensitiveContains("<html"))
    }

    @Test("Image exports re-encode to the requested format")
    func imageReencode() throws {
        let jpeg = try FileExporter.data(for: Self.pngItem(), format: .jpeg)
        #expect(ImageProcessor.format(of: jpeg) == .jpeg)
    }

    @Test("Suggested filename slugifies leading words of text")
    func suggestedNameFromText() {
        let item = ClipboardItem(content: .text("The Quick Brown Fox jumps"), contentType: .plainText)
        #expect(FileExporter.suggestedBaseName(for: item) == "the-quick-brown-fox-jumps")
    }

    @Test("Suggested filename falls back to a label for images")
    func suggestedNameForImage() {
        #expect(FileExporter.suggestedBaseName(for: Self.pngItem()) == "image")
    }

    @Test("Empty text yields a generic clipping name")
    func suggestedNameEmpty() {
        let item = ClipboardItem(content: .text("   "), contentType: .plainText)
        #expect(FileExporter.suggestedBaseName(for: item) == "clipping")
    }
}
