import AppKit
@testable import Clipped
import Foundation
import Testing

@MainActor
struct SVGHandlingTests {
    // A minimal valid SVG: one red 100x100 rectangle, no extensions, will round-trip
    // through `NSImage(data:)` cleanly on macOS 15.
    private static let minimalSVG = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">
      <rect width="100" height="100" fill="#ff0000"/>
    </svg>
    """

    private static let bareSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>
    """

    // MARK: - SVGDetector

    @Test("Detector recognizes a canonical SVG with XML prolog")
    func detectsCanonicalSVG() {
        #expect(SVGDetector.looksLikeSVG(Self.minimalSVG))
    }

    @Test("Detector recognizes a bare <svg> element with no prolog")
    func detectsBareSVG() {
        #expect(SVGDetector.looksLikeSVG(Self.bareSVG))
    }

    @Test("Detector tolerates leading whitespace")
    func detectsWithLeadingWhitespace() {
        #expect(SVGDetector.looksLikeSVG("   \n\t<svg></svg>"))
    }

    @Test("Detector rejects plain text")
    func rejectsPlainText() {
        #expect(!SVGDetector.looksLikeSVG("hello world"))
    }

    @Test("Detector rejects HTML fragments that happen to contain svg deeper in the tree")
    func rejectsHTMLContainingSVG() {
        // Article starts with a paragraph, not an <svg> root element.
        let html = "<p>Look at this icon: <svg><circle r='5'/></svg></p>"
        #expect(!SVGDetector.looksLikeSVG(html))
    }

    @Test("Detector rejects JSON and XML that isn't SVG")
    func rejectsOtherMarkup() {
        #expect(!SVGDetector.looksLikeSVG("{\"hello\": \"world\"}"))
        #expect(!SVGDetector.looksLikeSVG("<?xml version=\"1.0\"?>\n<rss></rss>"))
    }

    @Test("Detector rejects empty and near-empty strings")
    func rejectsEmpty() {
        #expect(!SVGDetector.looksLikeSVG(""))
        #expect(!SVGDetector.looksLikeSVG("<"))
        #expect(!SVGDetector.looksLikeSVG("<svgnotreally"))
    }

    // MARK: - Pasteboard ingestion

    @Test("Monitor ingests SVG markup copied as plain text as a .svg item")
    func ingestsSVGFromPlainText() {
        let mock = MockPasteboard()
        let monitor = PasteboardMonitor(pasteboard: mock)

        var captured: ClipboardItem?
        monitor.onNewItem = { captured = $0.item }

        mock.stageExternalWrite(types: [.string], strings: [.string: Self.minimalSVG])
        monitor.check()

        guard case let .svg(data, size) = captured?.content else {
            Issue.record("Expected SVG content, got \(String(describing: captured?.content))")
            return
        }
        #expect(String(data: data, encoding: .utf8) == Self.minimalSVG)
        #expect(size.width > 0)
        #expect(size.height > 0)
        #expect(captured?.contentType == .image)
    }

    @Test("Monitor prefers public.svg-image data over raster fallback")
    func ingestsSVGFromUTI() {
        let mock = MockPasteboard()
        let monitor = PasteboardMonitor(pasteboard: mock)

        var captured: ClipboardItem?
        monitor.onNewItem = { captured = $0.item }

        let svgData = Data(Self.bareSVG.utf8)
        // A 1x1 PNG fallback — monitor should prefer the vector source.
        let onePixelPNG = Data([
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

        mock.stageExternalWrite(
            types: [svgPasteboardType, .png],
            data: [svgPasteboardType: svgData, .png: onePixelPNG]
        )
        monitor.check()

        guard case let .svg(data, _) = captured?.content else {
            Issue.record("Expected SVG content, got \(String(describing: captured?.content))")
            return
        }
        #expect(data == svgData)
    }

    @Test("Monitor falls back to plain text if SVG data can't be rendered")
    func invalidSVGFallsThroughToText() {
        let mock = MockPasteboard()
        let monitor = PasteboardMonitor(pasteboard: mock)

        var captured: ClipboardItem?
        monitor.onNewItem = { captured = $0.item }

        // Starts with `<svg` but is not a valid SVG document — NSImage should refuse
        // to render it, and we should fall through to treating it as plain text.
        let garbage = "<svg this is not valid markup"
        mock.stageExternalWrite(types: [.string], strings: [.string: garbage])
        monitor.check()

        if case .svg = captured?.content {
            Issue.record("Invalid SVG should not have been ingested as .svg")
        }
        #expect(captured?.plainText == garbage)
    }

    // MARK: - ClipboardManager copy-out

    @Test("copyToClipboard writes SVG markup, vector UTI, and TIFF raster fallback")
    func copyWritesAllSVGRepresentations() {
        let mock = MockPasteboard()
        let manager = ClipboardManager(pasteboard: mock)
        manager.stopMonitoring()
        let settings = MockSettingsManager()
        manager.settingsManager = settings
        manager.historyStore = MockHistoryStore()

        let svgData = Data(Self.bareSVG.utf8)
        // Need to supply a realistic size so `preview` doesn't trip over 0x0 values.
        let item = ClipboardItem(
            content: .svg(svgData, CGSize(width: 10, height: 10)),
            contentType: .image
        )
        manager.copyToClipboard(item)

        #expect(mock.string(forType: .string) == Self.bareSVG)
        #expect(mock.data(forType: svgPasteboardType) == svgData)
        #expect(mock.data(forType: .tiff) != nil)
    }

    // MARK: - Persistence round-trip

    @Test("StoredEntry round-trips an SVG item through the in-memory JSON envelope")
    func storedEntryRoundTripsSVG() {
        let svgData = Data(Self.bareSVG.utf8)
        let item = ClipboardItem(
            content: .svg(svgData, CGSize(width: 10, height: 10)),
            contentType: .image
        )
        let entry = StoredEntry(item: item)
        #expect(entry.svgData == svgData)
        #expect(entry.imageData == nil)

        // Going through the JSON envelope (same path `HistoryStore.save/load` takes)
        // must preserve the SVG.
        let encoded = try? JSONEncoder().encode([entry])
        #expect(encoded != nil)
        let decoded = encoded.flatMap { try? JSONDecoder().decode([StoredEntry].self, from: $0) }
        let restored = decoded?.first?.toClipboardItem()
        guard case let .svg(data, size) = restored?.content else {
            Issue.record("Expected .svg after round-trip, got \(String(describing: restored?.content))")
            return
        }
        #expect(data == svgData)
        #expect(size.width == 10)
        #expect(size.height == 10)
    }

    @Test("Preview string describes SVG with dimensions")
    func previewShowsSVGDimensions() {
        let item = ClipboardItem(
            content: .svg(Data(Self.bareSVG.utf8), CGSize(width: 24, height: 24)),
            contentType: .image
        )
        #expect(item.preview == "SVG — 24×24")
        #expect(item.plainText == Self.bareSVG)
    }
}
