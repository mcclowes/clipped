import AppKit
@testable import Clipped
import Foundation
import Testing

@MainActor
struct ImageTextExtractorTests {
    @Test("Vision recognizes text from a generated local image", .bug(id: 127))
    func recognizesText() async throws {
        let text = try #require(await ImageTextExtractor.extractText(from: Self.textPNG()))
        let lines = text.components(separatedBy: .newlines).map { $0.lowercased() }
        #expect(Set(lines) == ["clipboard test", "local image"])
    }

    @Test("Images without text do not produce an OCR result", .bug(id: 127))
    func blankImage() async {
        let data = TestImageFactory.data(width: 800, height: 240)
        #expect(await ImageTextExtractor.extractText(from: data) == nil)
    }

    @Test("Empty and corrupt image data are rejected", .bug(id: 127), arguments: [
        Data(),
        Data("not an image".utf8),
        Data([0x89, 0x50, 0x4E, 0x47]),
    ])
    func invalidImage(_ data: Data) async {
        #expect(await ImageTextExtractor.extractText(from: data) == nil)
    }

    private static func textPNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 800, height: 240))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 48, weight: .regular),
            .foregroundColor: NSColor.black,
        ]
        "Clipboard test".draw(at: NSPoint(x: 50, y: 150), withAttributes: attributes)
        "Local image".draw(at: NSPoint(x: 50, y: 60), withAttributes: attributes)
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
