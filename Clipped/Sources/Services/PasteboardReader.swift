import AppKit
import Foundation
import os

/// UTI for SVG content on the pasteboard. Browsers, design tools, and some editors
/// advertise SVG images with this type alongside the raw XML under `.string`.
let svgPasteboardType = NSPasteboard.PasteboardType("public.svg-image")

/// Decodes pasteboard representations in priority order, preserving source metadata and bounded payloads.
@MainActor
struct PasteboardReader {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "PasteboardMonitor")

    private let pasteboard: PasteboardProtocol

    /// Skip ingesting raster payloads larger than this so a giant copy can't stall the UI or
    /// exhaust memory. The compact original still round-trips for reasonably sized images.
    nonisolated static let maxImageBytes = 64 * 1024 * 1024
    /// Content classifiers (dev/category/secret detection) only see this many characters — a
    /// multi-megabyte blob would otherwise run several regex passes on the poll loop.
    private static let maxDetectorChars = 100_000
    /// HTML above this size isn't converted to rich text on the (main-actor) poll path.
    private static let maxHTMLBytes = 256 * 1024

    private static let htmlType = NSPasteboard.PasteboardType("public.html")

    init(pasteboard: PasteboardProtocol) {
        self.pasteboard = pasteboard
    }

    func read(
        appName: String?,
        bundleID: String?
    ) -> ClipboardItem? {
        let types = pasteboard.types ?? []

        // 1. SVG (vector) before raster — some apps advertise both SVG and a rendered fallback.
        if types.contains(svgPasteboardType),
           let svgData = pasteboard.data(forType: svgPasteboardType),
           let item = makeSVGItem(data: svgData, appName: appName, bundleID: bundleID)
        {
            return item
        }

        // 2. Rich text (RTF) BEFORE any raster image. Numbers/Excel/Notes/web pages put a `.tiff`
        //    rendering *and* the real `.rtf`/`.string` on the pasteboard; preserving the text lets
        //    the user paste it back, search it, and mutate it instead of getting a picture of it.
        if types.contains(.rtf), let rtfData = pasteboard.data(forType: .rtf) {
            let plainText = pasteboard.string(forType: .string) ?? ""
            let item = ClipboardItem(
                content: .richText(rtfData, plainText),
                contentType: .richText,
                sourceAppName: appName,
                sourceAppBundleID: bundleID
            )
            item.htmlData = boundedHTMLData(from: types)
            return item
        }

        // 3. Raster image. Skip oversized payloads, and read the pixel size via ImageIO instead
        //    of a full `NSImage` decode (cheaper, and gives pixels not DPI-scaled points).
        if types.contains(.tiff) || types.contains(.png),
           let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        {
            guard imageData.count <= Self.maxImageBytes else {
                Self.logger.debug("Skipping oversized image copy (\(imageData.count) bytes)")
                return nil
            }
            guard let size = ImageProcessor.pixelSize(of: imageData) else {
                return nil
            }
            return ClipboardItem(
                content: .image(imageData, size),
                contentType: .image,
                sourceAppName: appName,
                sourceAppBundleID: bundleID
            )
        }

        // 4. HTML-only rich content (browsers may provide `public.html` + `.string`, no RTF).
        if let item = makeHTMLItem(appName: appName, bundleID: bundleID, types: types) {
            return item
        }

        // 5. URL — read the value from the `.URL` type itself, not a co-present `.string` (whose
        //    value may be the visible anchor text rather than the href).
        if types.contains(.URL),
           let urlString = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string),
           let url = URL(string: urlString),
           url.scheme == "http" || url.scheme == "https"
        {
            return ClipboardItem(
                content: .url(url),
                contentType: .url,
                sourceAppName: appName,
                sourceAppBundleID: bundleID
            )
        }

        // 6. Plain text / code.
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return makeTextItem(string: string, appName: appName, bundleID: bundleID, types: types)
        }

        return nil
    }

    /// Build a text/URL/SVG item from a plain string, bounding classifier input so a huge blob
    /// can't run several regex passes on the poll loop.
    private func makeTextItem(
        string: String,
        appName: String?,
        bundleID: String?,
        types: [NSPasteboard.PasteboardType]
    ) -> ClipboardItem {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(" "), !trimmed.contains("\n"),
           let url = URL(string: trimmed),
           url.scheme == "http" || url.scheme == "https"
        {
            return ClipboardItem(
                content: .url(url),
                contentType: .url,
                sourceAppName: appName,
                sourceAppBundleID: bundleID
            )
        }

        if SVGDetector.looksLikeSVG(string),
           let svgData = string.data(using: .utf8),
           let item = makeSVGItem(data: svgData, appName: appName, bundleID: bundleID)
        {
            return item
        }

        let sample = String(string.prefix(Self.maxDetectorChars))
        let sourceCategory = bundleID.flatMap(SourceAppCategory.category(for:))
        let isFromDevApp = sourceCategory == .codeEditor || sourceCategory == .terminal
        let isDevContent = isFromDevApp || DeveloperContentDetector.isDeveloperContent(sample)
        let detectedCategories = ContentCategoryDetector.detect(in: sample)
        let item = ClipboardItem(
            content: .text(string),
            contentType: .plainText,
            sourceAppName: appName,
            sourceAppBundleID: bundleID,
            isDeveloperContent: isDevContent,
            detectedCategories: detectedCategories
        )
        attachCustomPasteboardTypesIfNeeded(to: item, bundleID: bundleID, types: types)
        return item
    }

    /// Convert `public.html` into rich text so browser formatting survives (and text mutations
    /// still apply). Bounded in size — HTML parsing is main-actor WebKit work.
    private func makeHTMLItem(
        appName: String?,
        bundleID: String?,
        types: [NSPasteboard.PasteboardType]
    ) -> ClipboardItem? {
        guard let htmlData = boundedHTMLData(from: types),
              let attributed = try? NSAttributedString(
                  data: htmlData,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue,
                  ],
                  documentAttributes: nil
              )
        else { return nil }

        let plain = attributed.string
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let fullRange = NSRange(location: 0, length: attributed.length)
        guard let rtfData = try? attributed.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else {
            return ClipboardItem(
                content: .text(plain),
                contentType: .plainText,
                sourceAppName: appName,
                sourceAppBundleID: bundleID
            )
        }
        let item = ClipboardItem(
            content: .richText(rtfData, plain),
            contentType: .richText,
            sourceAppName: appName,
            sourceAppBundleID: bundleID
        )
        item.htmlData = htmlData
        return item
    }

    private func boundedHTMLData(
        from types: [NSPasteboard.PasteboardType]
    ) -> Data? {
        guard types.contains(Self.htmlType),
              let data = pasteboard.data(forType: Self.htmlType),
              data.count <= Self.maxHTMLBytes
        else { return nil }
        return data
    }

    private func attachCustomPasteboardTypesIfNeeded(
        to item: ClipboardItem,
        bundleID: String?,
        types: [NSPasteboard.PasteboardType]
    ) {
        guard AppPasteboardProfiles.profile(for: bundleID) != nil else { return }
        item.customPasteboardTypes = snapshotPasteboardTypes(types: types)
    }

    /// Snapshot every pasteboard type's data so we can replay the full payload on copy.
    /// Total captured size is capped so a giant app payload can't blow up history memory.
    private func snapshotPasteboardTypes(
        types: [NSPasteboard.PasteboardType]
    ) -> [String: Data]? {
        var result: [String: Data] = [:]
        var totalBytes = 0
        let maxTotalBytes = 2 * 1024 * 1024
        for type in types {
            guard let data = pasteboard.data(forType: type) else { continue }
            totalBytes += data.count
            if totalBytes > maxTotalBytes {
                return nil
            }
            result[type.rawValue] = data
        }
        return result.isEmpty ? nil : result
    }

    /// Validate SVG data by rendering it through `NSImage` and wrap it in a `.svg`
    /// ClipboardItem on success. Returns `nil` if the data is not a readable SVG, so
    /// the caller can fall through to treating the content as plain text.
    private func makeSVGItem(
        data: Data,
        appName: String?,
        bundleID: String?
    ) -> ClipboardItem? {
        // `NSImage(data:)` supports SVG natively on macOS 14+ (our deployment target is
        // 15). If a given SVG fails to render (unusual features, malformed XML), we
        // decline rather than silently storing something we can't preview.
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        return ClipboardItem(
            content: .svg(data, image.size),
            contentType: .image,
            sourceAppName: appName,
            sourceAppBundleID: bundleID
        )
    }
}
