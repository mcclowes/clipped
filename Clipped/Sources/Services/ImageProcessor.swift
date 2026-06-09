import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Raster image formats Clipped can encode to. Used by both the image-utility
/// menu actions (`ClipboardManager`) and "Save as…" (`FileExporter`).
enum RasterImageFormat: String, CaseIterable {
    case png
    case jpeg
    case heic

    var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }

    /// Human-facing label for menus and the save panel's format picker.
    var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }
}

/// On-device image transforms backed by ImageIO. Pure (`Data` → `Data`) and
/// stateless so it stays trivially unit-testable; no network, no third-party
/// service — every operation happens locally.
enum ImageProcessor {
    /// Pixel dimensions of an encoded image without fully decoding it.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Best-effort detection of an encoded image's format, used to preserve the
    /// source format when resizing. Returns `nil` for formats we don't re-encode
    /// to (e.g. GIF, TIFF) so callers can fall back to a sensible default.
    static func format(of data: Data) -> RasterImageFormat? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source) as String?,
              let type = UTType(uti)
        else { return nil }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
        return nil
    }

    /// Re-encode an image to `format`. For lossy formats (JPEG/HEIC) `quality`
    /// controls the compression trade-off (0 = smallest, 1 = best fidelity);
    /// it's ignored by PNG. This is both "compress" (re-encode lossily) and
    /// "convert" (change container).
    static func reencode(_ data: Data, to format: RasterImageFormat, quality: Double = 0.7) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return encode(image, to: format, quality: quality)
    }

    /// Downscale by `scale` (e.g. 0.5 = half size), preserving the source format
    /// where we recognise it and otherwise emitting PNG. A `scale` of 1 or more
    /// is a no-op guard (we only downscale) and returns `nil`.
    static func resize(_ data: Data, scale: Double, quality: Double = 0.9) -> Data? {
        guard scale > 0, scale < 1,
              let original = pixelSize(of: data),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        let maxDimension = max(original.width, original.height) * scale
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension.rounded()),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return encode(thumbnail, to: format(of: data) ?? .png, quality: quality)
    }

    private static func encode(_ image: CGImage, to format: RasterImageFormat, quality: Double) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            format.utType.identifier as CFString,
            1,
            nil
        ) else { return nil }

        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}
