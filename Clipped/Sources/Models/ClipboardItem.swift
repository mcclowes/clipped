import AppKit
import Foundation
import Observation

enum ContentType: String, CaseIterable, Identifiable {
    case plainText = "Text"
    case richText = "Rich Text"
    case url = "URL"
    case image = "Image"

    var id: String {
        rawValue
    }

    var systemImage: String {
        switch self {
        case .plainText: "doc.text"
        case .richText: "doc.richtext"
        case .url: "link"
        case .image: "photo"
        }
    }
}

/// Lightweight content-derived tags that can overlap freely with each other and with the
/// developer flag. An item with the text "Email me at a@b.com" is both `.email` and regular
/// text; the filter bar treats each as an independent pivot.
enum ContentCategory: String, CaseIterable, Identifiable, Codable {
    case email
    case phoneNumber
    case hexColor
    case number
    case ipAddress
    case macAddress

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .email: "Email"
        case .phoneNumber: "Phone"
        case .hexColor: "Color"
        case .number: "Number"
        case .ipAddress: "IP Address"
        case .macAddress: "MAC Address"
        }
    }

    var systemImage: String {
        switch self {
        case .email: "envelope"
        case .phoneNumber: "phone"
        case .hexColor: "paintpalette"
        case .number: "number"
        case .ipAddress: "network"
        case .macAddress: "cable.connector"
        }
    }

    var settingsDescription: String {
        switch self {
        case .email: "Items containing an email address"
        case .phoneNumber: "Items containing a phone number"
        case .hexColor: "Items containing a #RRGGBB hex color"
        case .number: "Amounts, percentages, currency values"
        case .ipAddress: "Items containing an IPv4 address"
        case .macAddress: "Items containing a hardware (MAC) address"
        }
    }
}

@MainActor
@Observable
final class ClipboardItem: Identifiable {
    private static let maxSecretScanCharacters = 100_000

    let id: UUID
    var content: ClipboardContent
    let contentType: ContentType
    let sourceAppName: String?
    let sourceAppBundleID: String?
    let timestamp: Date
    var isPinned: Bool
    /// Transient flag for items we must not persist to disk (password-manager output).
    /// Implies UI masking but also gates persistence — see `HistoryStore` / `StoredEntry`.
    var isSensitive: Bool
    /// Persistent flag for items whose *content* matches a known secret pattern.
    /// Masks the preview and detail views but the raw bytes still round-trip so paste works.
    var containsSecret: Bool
    var isDeveloperContent: Bool
    var detectedCategories: Set<ContentCategory>
    var linkTitle: String?
    var linkFavicon: Data?
    /// Text extracted from image content via on-device OCR. Populated asynchronously
    /// after ingest; `nil` until recognition completes or if the image contains no text.
    var extractedText: String?
    /// New images stay out of saved history until OCR has classified any embedded secrets.
    var isAwaitingImageText = false
    var originalContent: ClipboardContent?
    var mutationsApplied: [String] = []
    /// Original HTML rendition captured alongside rich text. Kept separately from the
    /// canonical RTF content so destinations that prefer HTML receive the source markup.
    var htmlData: Data?
    /// Raw pasteboard type → data snapshot captured for items that come from apps with
    /// custom UTIs (Logic Pro regions, etc.). Replayed on copy so pasting back into the
    /// source app still works. Keys are pasteboard type identifiers (UTIs).
    var customPasteboardTypes: [String: Data]?

    var sourceAppCategory: SourceAppCategory? {
        guard let bundleID = sourceAppBundleID else { return nil }
        return SourceAppCategory.category(for: bundleID)
    }

    var wasMutated: Bool {
        !mutationsApplied.isEmpty
    }

    var availableRepresentations: [ClipboardRepresentation] {
        switch content {
        case .richText:
            var formats: [ClipboardRepresentation] = []
            if htmlData != nil {
                formats.append(.html)
            }
            formats.append(contentsOf: [.richText, .plainText, .markdown])
            return formats
        case .text, .url:
            return [.plainText]
        case .image, .svg:
            return []
        }
    }

    var plainText: String? {
        switch content {
        case let .text(string): string
        case let .richText(_, plainFallback): plainFallback
        case let .url(url): url.absoluteString
        case let .svg(data, _): String(data: data, encoding: .utf8)
        default: nil
        }
    }

    /// App-specific pretty preview (e.g. "Logic Pro region — Guitar") when the item was
    /// captured from a known app with a custom pasteboard format. Falls back to `nil`
    /// so callers can use the default `preview`.
    var appSpecificPreview: String? {
        guard let profile = AppPasteboardProfiles.profile(for: sourceAppBundleID),
              case let .text(string) = content
        else { return nil }
        return profile.prettyPreview(string)
    }

    /// Full text used for search — unlike `preview`, this is not truncated, so a match deep
    /// inside a long item is still found.
    var searchableText: String {
        plainText ?? preview
    }

    var preview: String {
        if let pretty = appSpecificPreview {
            return pretty
        }
        return switch content {
        case let .text(string):
            String(string.prefix(200))
        case let .richText(_, plain):
            String(plain.prefix(200))
        case let .url(url):
            url.absoluteString
        case let .image(_, size):
            "Image — \(Int(size.width))×\(Int(size.height))"
        case let .svg(_, size):
            "SVG — \(Int(size.width))×\(Int(size.height))"
        }
    }

    init(
        id: UUID = UUID(),
        content: ClipboardContent,
        contentType: ContentType,
        sourceAppName: String? = nil,
        sourceAppBundleID: String? = nil,
        timestamp: Date = Date(),
        isPinned: Bool = false,
        isSensitive: Bool = false,
        containsSecret: Bool = false,
        isDeveloperContent: Bool = false,
        detectedCategories: Set<ContentCategory> = []
    ) {
        self.id = id
        self.content = content
        self.contentType = contentType
        self.sourceAppName = sourceAppName
        self.sourceAppBundleID = sourceAppBundleID
        self.timestamp = timestamp
        self.isPinned = isPinned
        self.isSensitive = isSensitive
        self.containsSecret = containsSecret
        self.isDeveloperContent = isDeveloperContent
        self.detectedCategories = detectedCategories
        if !containsSecret, let text = plainText {
            self.containsSecret = SecretDetector.containsSecret(String(text.prefix(Self.maxSecretScanCharacters)))
        }
    }
}

enum ClipboardContent: Equatable {
    case text(String)
    case richText(Data, String) // RTF data + plain text fallback
    case url(URL)
    case image(Data, CGSize) // image data + dimensions
    case svg(Data, CGSize) // SVG markup (UTF-8 bytes) + rendered dimensions
}
