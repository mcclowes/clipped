import Foundation

/// Codable projection of `ClipboardContent`, used to persist `originalContent` (the pre-mutation
/// value that powers "Restore original") through the storage layer. All associated values are
/// value types, so this stays `Sendable`.
enum StoredContent: Codable {
    case text(String)
    case richText(Data, String)
    case url(String)
    case image(Data, Double, Double)
    case svg(Data, Double, Double)

    init(_ content: ClipboardContent) {
        switch content {
        case let .text(string): self = .text(string)
        case let .richText(data, plain): self = .richText(data, plain)
        case let .url(url): self = .url(url.absoluteString)
        case let .image(data, size): self = .image(data, size.width, size.height)
        case let .svg(data, size): self = .svg(data, size.width, size.height)
        }
    }

    func toClipboardContent() -> ClipboardContent? {
        switch self {
        case let .text(string): .text(string)
        case let .richText(data, plain): .richText(data, plain)
        case let .url(string): URL(string: string).map(ClipboardContent.url)
        case let .image(data, width, height): .image(data, CGSize(width: width, height: height))
        case let .svg(data, width, height): .svg(data, CGSize(width: width, height: height))
        }
    }
}

/// Serialization-friendly snapshot of a ClipboardItem. Conversions that touch
/// ClipboardItem live in a @MainActor extension so this struct itself is Sendable
/// by default (all stored properties are value types).
struct StoredEntry: Codable {
    let id: UUID
    let contentType: String
    let textContent: String?
    let rtfData: Data?
    /// Original HTML rendition for rich-text entries. Nullable for histories written before
    /// multi-representation capture was added.
    let htmlData: Data?
    let urlString: String?
    let imageData: Data?
    let imageWidth: Double?
    let imageHeight: Double?
    /// Raw SVG markup bytes. Stored inline in `history.enc` since SVG is text —
    /// the external image-file path is reserved for raster payloads.
    let svgData: Data?
    let sourceAppName: String?
    let sourceAppBundleID: String?
    let timestamp: Date
    let isPinned: Bool
    let isDeveloperContent: Bool?
    /// Nullable for backward compat with history files written before secret detection existed.
    let containsSecret: Bool?
    let linkTitle: String?
    let linkFavicon: Data?
    let mutationsApplied: [String]?
    /// Nullable for backward compat with v1 history files that predate content categories.
    let detectedCategories: [String]?
    /// Opaque pasteboard payloads captured from apps with custom UTIs (Logic Pro, etc.)
    /// so paste into the source app still works after history reload. Nullable for
    /// backward compat with history files written before this existed.
    let customPasteboardTypes: [String: Data]?
    /// Text recognised from image content by on-device OCR. Populated asynchronously
    /// after ingest; nullable for backward compat with older history files.
    let extractedText: String?
    /// Pre-mutation content, so "Restore original" survives a relaunch. Nullable for
    /// backward compat and for items that were never mutated.
    let originalContent: StoredContent?

    /// Copy of this entry with the raster `imageData` cleared, used when writing the JSON
    /// envelope so a 4 MB screenshot doesn't round-trip as base64 inside the history file.
    /// Everything else — including `customPasteboardTypes` (2 MB-capped) and `originalContent`
    /// — is preserved so paste-back and restore keep working across relaunches.
    func strippingImageData() -> StoredEntry {
        replacingImageData(nil)
    }

    /// Copy of this entry with `imageData` hydrated from disk during load.
    func withImageData(_ data: Data) -> StoredEntry {
        replacingImageData(data)
    }

    private func replacingImageData(_ data: Data?) -> StoredEntry {
        StoredEntry(
            id: id,
            contentType: contentType,
            textContent: textContent,
            rtfData: rtfData,
            htmlData: htmlData,
            urlString: urlString,
            imageData: data,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            svgData: svgData,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID,
            timestamp: timestamp,
            isPinned: isPinned,
            isDeveloperContent: isDeveloperContent,
            containsSecret: containsSecret,
            linkTitle: linkTitle,
            linkFavicon: linkFavicon,
            mutationsApplied: mutationsApplied,
            detectedCategories: detectedCategories,
            customPasteboardTypes: customPasteboardTypes,
            extractedText: extractedText,
            originalContent: originalContent
        )
    }
}

@MainActor
extension StoredEntry {
    init(item: ClipboardItem) {
        let textContent: String?
        let rtfData: Data?
        let urlString: String?
        let imageData: Data?
        let svgData: Data?
        let imageWidth: Double?
        let imageHeight: Double?

        switch item.content {
        case let .text(string):
            textContent = string
            rtfData = nil
            urlString = nil
            imageData = nil
            svgData = nil
            imageWidth = nil
            imageHeight = nil
        case let .richText(data, plain):
            textContent = plain
            rtfData = data
            urlString = nil
            imageData = nil
            svgData = nil
            imageWidth = nil
            imageHeight = nil
        case let .url(url):
            textContent = nil
            rtfData = nil
            urlString = url.absoluteString
            imageData = nil
            svgData = nil
            imageWidth = nil
            imageHeight = nil
        case let .image(data, size):
            textContent = nil
            rtfData = nil
            urlString = nil
            imageData = data
            svgData = nil
            imageWidth = size.width
            imageHeight = size.height
        case let .svg(data, size):
            textContent = nil
            rtfData = nil
            urlString = nil
            imageData = nil
            svgData = data
            imageWidth = size.width
            imageHeight = size.height
        }

        self.init(
            id: item.id,
            contentType: item.contentType.rawValue,
            textContent: textContent,
            rtfData: rtfData,
            htmlData: item.htmlData,
            urlString: urlString,
            imageData: imageData,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            svgData: svgData,
            sourceAppName: item.sourceAppName,
            sourceAppBundleID: item.sourceAppBundleID,
            timestamp: item.timestamp,
            isPinned: item.isPinned,
            isDeveloperContent: item.isDeveloperContent,
            containsSecret: item.containsSecret ? true : nil,
            linkTitle: item.linkTitle,
            linkFavicon: item.linkFavicon,
            mutationsApplied: item.mutationsApplied.isEmpty ? nil : item.mutationsApplied,
            detectedCategories: item.detectedCategories.isEmpty
                ? nil
                : item.detectedCategories.map(\.rawValue).sorted(),
            customPasteboardTypes: item.customPasteboardTypes,
            extractedText: item.extractedText,
            originalContent: item.originalContent.map(StoredContent.init)
        )
    }

    func toClipboardItem() -> ClipboardItem? {
        let resolvedType = contentType == "Code" ? "Text" : contentType
        guard let type = ContentType(rawValue: resolvedType),
              let content = decodeContent(for: type) else { return nil }

        let decodedCategories: Set<ContentCategory> = Set(
            (detectedCategories ?? []).compactMap(ContentCategory.init(rawValue:))
        )
        let item = ClipboardItem(
            id: id,
            content: content,
            contentType: type,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID,
            timestamp: timestamp,
            isPinned: isPinned,
            containsSecret: containsSecret ?? false,
            isDeveloperContent: isDeveloperContent ?? false,
            detectedCategories: decodedCategories
        )
        item.linkTitle = linkTitle
        item.linkFavicon = linkFavicon
        item.mutationsApplied = mutationsApplied ?? []
        item.htmlData = htmlData
        item.customPasteboardTypes = customPasteboardTypes
        item.extractedText = extractedText
        item.originalContent = originalContent?.toClipboardContent()
        return item
    }

    private func decodeContent(for type: ContentType) -> ClipboardContent? {
        switch type {
        case .plainText:
            return textContent.map(ClipboardContent.text)
        case .richText:
            if let rtf = rtfData, let plain = textContent {
                return .richText(rtf, plain)
            }
            return textContent.map(ClipboardContent.text)
        case .url:
            guard let str = urlString, let url = URL(string: str) else { return nil }
            return .url(url)
        case .image:
            let size = CGSize(width: imageWidth ?? 0, height: imageHeight ?? 0)
            // SVG entries ride on ContentType.image but carry their bytes in `svgData`.
            if let data = svgData {
                return .svg(data, size)
            }
            return imageData.map { .image($0, size) }
        }
    }
}
