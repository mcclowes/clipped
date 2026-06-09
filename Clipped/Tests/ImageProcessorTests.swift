@testable import Clipped
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@MainActor
struct ImageProcessorTests {
    private static func makeImage(width: Int, height: Int, format: RasterImageFormat = .png) -> Data {
        TestImageFactory.data(width: width, height: height, format: format)
    }

    @Test("pixelSize reads dimensions without decoding")
    func pixelSize() throws {
        let data = Self.makeImage(width: 120, height: 80)
        let size = try #require(ImageProcessor.pixelSize(of: data))
        #expect(Int(size.width) == 120)
        #expect(Int(size.height) == 80)
    }

    @Test("pixelSize returns nil for non-image data")
    func pixelSizeInvalid() {
        #expect(ImageProcessor.pixelSize(of: Data("not an image".utf8)) == nil)
    }

    @Test("format detects PNG and JPEG sources")
    func formatDetection() {
        #expect(ImageProcessor.format(of: Self.makeImage(width: 10, height: 10, format: .png)) == .png)
        #expect(ImageProcessor.format(of: Self.makeImage(width: 10, height: 10, format: .jpeg)) == .jpeg)
    }

    @Test("reencode to JPEG preserves dimensions and emits JPEG bytes")
    func reencodeToJPEG() throws {
        let png = Self.makeImage(width: 64, height: 48, format: .png)
        let jpeg = try #require(ImageProcessor.reencode(png, to: .jpeg))
        #expect(ImageProcessor.format(of: jpeg) == .jpeg)
        let size = try #require(ImageProcessor.pixelSize(of: jpeg))
        #expect(Int(size.width) == 64)
        #expect(Int(size.height) == 48)
    }

    @Test("reencode to PNG emits PNG bytes")
    func reencodeToPNG() throws {
        let jpeg = Self.makeImage(width: 32, height: 32, format: .jpeg)
        let png = try #require(ImageProcessor.reencode(jpeg, to: .png))
        #expect(ImageProcessor.format(of: png) == .png)
    }

    @Test("reencode to HEIC decodes back to the same size")
    func reencodeToHEIC() throws {
        let png = Self.makeImage(width: 40, height: 40)
        let heic = try #require(ImageProcessor.reencode(png, to: .heic))
        let size = try #require(ImageProcessor.pixelSize(of: heic))
        #expect(Int(size.width) == 40)
        #expect(Int(size.height) == 40)
    }

    @Test("reencode returns nil for non-image data")
    func reencodeInvalid() {
        #expect(ImageProcessor.reencode(Data([0x00, 0x01, 0x02]), to: .jpeg) == nil)
    }

    @Test("resize halves the largest dimension and preserves format")
    func resizeHalf() throws {
        let png = Self.makeImage(width: 200, height: 100, format: .png)
        let resized = try #require(ImageProcessor.resize(png, scale: 0.5))
        let size = try #require(ImageProcessor.pixelSize(of: resized))
        #expect(Int(size.width) == 100)
        #expect(ImageProcessor.format(of: resized) == .png)
    }

    @Test("resize rejects scale of 1 or more")
    func resizeNoUpscale() {
        let png = Self.makeImage(width: 50, height: 50)
        #expect(ImageProcessor.resize(png, scale: 1.0) == nil)
        #expect(ImageProcessor.resize(png, scale: 2.0) == nil)
    }
}
