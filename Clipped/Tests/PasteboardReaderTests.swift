import AppKit
@testable import Clipped
import Foundation
import ImageIO
import Testing

@MainActor
struct PasteboardReaderTests {
    @Test("Raster dimensions stay in pixels for DPI-scaled PNG and TIFF copies", arguments: [
        NSBitmapImageRep.FileType.png, .tiff,
    ])
    func rasterDimensions(format: NSBitmapImageRep.FileType) throws {
        let bitmap = try #require(NSBitmapImageRep(data: TestImageFactory.data(width: 120, height: 80)))
        bitmap.size = CGSize(width: 60, height: 40)
        let data = try #require(bitmap.representation(using: format, properties: [:]))
        let image = try #require(NSImage(data: data))
        try #require(abs(image.size.width - 60) < 0.1 && abs(image.size.height - 40) < 0.1)
        #expect(ImageProcessor.pixelSize(of: data) == CGSize(width: 120, height: 80))
        let type: NSPasteboard.PasteboardType = format == .png ? .png : .tiff
        let mock = MockPasteboard()
        mock.stageExternalWrite(types: [type], data: [type: data])

        let item = try #require(PasteboardReader(pasteboard: mock).read(appName: "Fixture", bundleID: "app.fixture"))

        #expect(item.content == .image(data, CGSize(width: 120, height: 80)))
        #expect(item.sourceAppName == "Fixture" && item.sourceAppBundleID == "app.fixture")
    }

    @Test("AppKit raster fallback requires a fixed pixel grid", .bug(id: 118), arguments: RasterPixelFixture.allCases)
    func rasterFallback(fixture: RasterPixelFixture) throws {
        NSImageRep.registerClass(RasterPixelImageRep.self)
        defer { NSImageRep.unregisterClass(RasterPixelImageRep.self) }
        let data = fixture.data
        let properties = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        try #require(properties?[kCGImagePropertyPixelWidth] == nil)
        try #require(properties?[kCGImagePropertyPixelHeight] == nil)
        let image = try #require(NSImage(data: data))
        try #require(image.size == CGSize(width: 60, height: 40))
        let rep = try #require(image.representations.first)
        try #require(rep.pixelsWide == fixture.width && rep.pixelsHigh == fixture.height)
        let expectedSize = fixture == .retina ? CGSize(width: 120, height: 80) : nil
        #expect(ImageProcessor.pixelSize(of: data) == expectedSize)
        let mock = MockPasteboard()
        mock.stageExternalWrite(types: [.png], data: [.png: data])

        let item = PasteboardReader(pasteboard: mock).read(appName: "Fixture", bundleID: "app.fixture")

        if let expectedSize {
            let retained = try #require(item)
            #expect(retained.content == .image(data, expectedSize))
            #expect(retained.sourceAppName == "Fixture" && retained.sourceAppBundleID == "app.fixture")
        } else {
            #expect(item == nil)
        }
    }

    @Test("Unreadable raster payloads are rejected", arguments: [NSPasteboard.PasteboardType.png, .tiff])
    func unreadableRaster(type: NSPasteboard.PasteboardType) {
        let mock = MockPasteboard()
        mock.stageExternalWrite(types: [type], data: [type: Data("invalid raster data".utf8)])

        #expect(PasteboardReader(pasteboard: mock).read(appName: nil, bundleID: nil) == nil)
    }

    @Test("Reader preserves source metadata and developer tagging", arguments: [
        ("Terminal", "com.apple.Terminal", true),
        ("Xcode", "com.apple.dt.Xcode", true),
        ("Notes", "com.apple.Notes", false),
    ])
    func sourceMetadata(appName: String, bundleID: String, isDeveloperContent: Bool) throws {
        let mock = MockPasteboard()
        mock.stageExternalWrite(types: [.string], strings: [.string: "Ordinary prose"])

        let item = try #require(PasteboardReader(pasteboard: mock).read(appName: appName, bundleID: bundleID))

        #expect(item.plainText == "Ordinary prose")
        #expect(item.sourceAppName == appName)
        #expect(item.sourceAppBundleID == bundleID)
        #expect(item.isDeveloperContent == isDeveloperContent)
    }

    @Test("Only profiled source apps retain custom pasteboard payloads", arguments: [
        "com.apple.logic10", "com.apple.Notes",
    ])
    func customPayloads(bundleID: String) throws {
        let mock = MockPasteboard()
        let customType = NSPasteboard.PasteboardType("com.apple.logic.region")
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let textData = Data("Guitar".utf8)
        mock.stageExternalWrite(
            types: [.string, customType],
            strings: [.string: "Guitar"],
            data: [.string: textData, customType: payload]
        )

        let item = try #require(PasteboardReader(pasteboard: mock).read(appName: nil, bundleID: bundleID))

        #expect(item.plainText == "Guitar")
        if bundleID == "com.apple.logic10" {
            #expect(item.customPasteboardTypes == [
                NSPasteboard.PasteboardType.string.rawValue: textData, customType.rawValue: payload,
            ])
        } else {
            #expect(item.customPasteboardTypes == nil)
        }
    }

    @Test("Custom payload budget is inclusive and applies to all representations", arguments: [false, true])
    func customPayloadBudget(exceedsBudget: Bool) throws {
        let mock = MockPasteboard()
        let customType = NSPasteboard.PasteboardType("com.apple.logic.region")
        let byteLimit = 2 * 1024 * 1024
        let payload = Data(repeating: 0, count: byteLimit - 1)
        let textData = Data(repeating: 0, count: exceedsBudget ? 2 : 1)
        mock.stageExternalWrite(
            types: [.string, customType],
            strings: [.string: "Guitar"],
            data: [.string: textData, customType: payload]
        )

        let item = try #require(PasteboardReader(pasteboard: mock).read(
            appName: "Logic Pro",
            bundleID: "com.apple.logic10"
        ))

        #expect(item.plainText == "Guitar")
        if exceedsBudget {
            #expect(item.customPasteboardTypes == nil)
        } else {
            let snapshot = try #require(item.customPasteboardTypes)
            #expect(snapshot.count == 2)
            #expect(snapshot.values.reduce(0) { $0 + $1.count } == byteLimit)
        }
    }
}

enum RasterPixelFixture: String, CaseIterable {
    case retina, noWidth, noHeight, vector

    var data: Data {
        Data("Clipped raster pixel fixture: \(rawValue)".utf8)
    }

    var width: Int {
        self == .retina || self == .noHeight ? 120 : 0
    }

    var height: Int {
        self == .retina || self == .noWidth ? 80 : 0
    }
}

private final class RasterPixelImageRep: NSImageRep {
    override static func canInit(with data: Data) -> Bool {
        RasterPixelFixture.allCases.contains { $0.data == data }
    }

    override static var imageUnfilteredTypes: [String] {
        ["com.clipped.tests.raster-pixel-fixture"]
    }

    @objc init?(data: Data) {
        guard let fixture = RasterPixelFixture.allCases.first(where: { $0.data == data }) else { return nil }
        super.init()
        size = NSSize(width: 60, height: 40)
        pixelsWide = fixture.width
        pixelsHigh = fixture.height
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
