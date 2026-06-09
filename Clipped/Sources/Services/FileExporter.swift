import AppKit
import Foundation
import UniformTypeIdentifiers

/// A file format a clipboard item can be exported to via "Save as…".
enum ExportFormat: String, CaseIterable {
    case markdown
    case plainText
    case richText
    case html
    case png
    case jpeg
    case heic

    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .plainText: "Plain text"
        case .richText: "Rich text (RTF)"
        case .html: "HTML"
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .plainText: "txt"
        case .richText: "rtf"
        case .html: "html"
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }

    /// Content type for `NSSavePanel.allowedContentTypes`. Markdown has no
    /// universal system type, so we derive a dynamic one from the extension.
    var utType: UTType {
        switch self {
        case .markdown: UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
        case .plainText: .plainText
        case .richText: .rtf
        case .html: .html
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }

    fileprivate var rasterFormat: RasterImageFormat? {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        default: nil
        }
    }
}

/// Derives the bytes, available formats, and a suggested filename for exporting a
/// `ClipboardItem` to disk. Pure and UI-free — the `NSSavePanel` presentation lives
/// in the view layer; everything decision-making happens here so it stays testable.
/// `@MainActor` because it reads `ClipboardItem`, which is main-actor isolated.
@MainActor
enum FileExporter {
    enum ExportError: Error {
        case unsupportedFormat
        case encodingFailed
    }

    /// Formats that make sense for an item, most natural first (drives the save
    /// panel's default selection).
    static func availableFormats(for item: ClipboardItem) -> [ExportFormat] {
        switch item.content {
        case .text: [.markdown, .plainText]
        case .richText: [.markdown, .richText, .html, .plainText]
        case .url: [.plainText, .markdown]
        case .image: [.png, .jpeg, .heic]
        case .svg: [.plainText, .png, .jpeg]
        }
    }

    static func data(for item: ClipboardItem, format: ExportFormat) throws -> Data {
        switch format {
        case .plainText:
            return try utf8(plainText(of: item))
        case .markdown:
            return try utf8(markdown(of: item))
        case .richText:
            guard case let .richText(rtfData, _) = item.content else { throw ExportError.unsupportedFormat }
            return rtfData
        case .html:
            return try html(of: item)
        case .png, .jpeg, .heic:
            return try imageData(of: item, format: format)
        }
    }

    /// Filename stem (no extension) suggested in the save panel. Derived from the
    /// item's text where there is some, otherwise a content-type label.
    static func suggestedBaseName(for item: ClipboardItem) -> String {
        switch item.content {
        case .image, .svg:
            return "image"
        case .text, .richText, .url:
            let source = item.plainText ?? ""
            let slug = slug(from: source)
            return slug.isEmpty ? "clipping" : slug
        }
    }

    // MARK: - Derivation

    private static func plainText(of item: ClipboardItem) throws -> String {
        guard let text = item.plainText else { throw ExportError.unsupportedFormat }
        return text
    }

    private static func markdown(of item: ClipboardItem) throws -> String {
        if case let .richText(rtfData, plain) = item.content {
            let converted = MarkdownConverter.convert(rtfData: rtfData)
            return (converted?.isEmpty == false ? converted : nil) ?? plain
        }
        return try plainText(of: item)
    }

    private static func html(of item: ClipboardItem) throws -> Data {
        let attributed: NSAttributedString = if case let .richText(rtfData, _) = item.content,
                                                let fromRTF = NSAttributedString(rtf: rtfData, documentAttributes: nil)
        {
            fromRTF
        } else {
            try NSAttributedString(string: plainText(of: item))
        }
        let range = NSRange(location: 0, length: attributed.length)
        guard let data = try? attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        ) else {
            throw ExportError.encodingFailed
        }
        return data
    }

    private static func imageData(of item: ClipboardItem, format: ExportFormat) throws -> Data {
        guard let raster = format.rasterFormat else { throw ExportError.unsupportedFormat }

        let sourceData: Data
        switch item.content {
        case let .image(data, _):
            sourceData = data
        case let .svg(data, _):
            // Rasterise the vector source before re-encoding.
            guard let tiff = NSImage(data: data)?.tiffRepresentation else { throw ExportError.encodingFailed }
            sourceData = tiff
        default:
            throw ExportError.unsupportedFormat
        }

        guard let encoded = ImageProcessor.reencode(sourceData, to: raster, quality: raster == .png ? 1.0 : 0.9) else {
            throw ExportError.encodingFailed
        }
        return encoded
    }

    private static func utf8(_ string: String) throws -> Data {
        guard let data = string.data(using: .utf8) else { throw ExportError.encodingFailed }
        return data
    }

    /// Lowercase, hyphen-joined slug from the first words of `source`, capped so
    /// filenames stay short.
    private static func slug(from source: String) -> String {
        let firstLine = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(60)
        let allowed = CharacterSet.alphanumerics
        let words = firstLine
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined() }
            .filter { !$0.isEmpty }
            .prefix(6)
        return words.joined(separator: "-")
    }
}
