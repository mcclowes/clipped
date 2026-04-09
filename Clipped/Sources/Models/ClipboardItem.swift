import AppKit
import Foundation

enum ContentType: String, CaseIterable, Identifiable, Sendable {
    case plainText = "Text"
    case richText = "Rich Text"
    case url = "URL"
    case code = "Code"
    case image = "Image"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .plainText: "doc.text"
        case .richText: "doc.richtext"
        case .url: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        }
    }
}

@MainActor
final class ClipboardItem: Identifiable, Sendable {
    let id: UUID
    let content: ClipboardContent
    let contentType: ContentType
    let sourceAppName: String?
    let sourceAppBundleID: String?
    let timestamp: Date
    var isPinned: Bool
    var linkTitle: String?

    var plainText: String? {
        switch content {
        case .text(let string): string
        case .richText(_, let plainFallback): plainFallback
        case .url(let url): url.absoluteString
        default: nil
        }
    }

    var preview: String {
        switch content {
        case .text(let string):
            String(string.prefix(200))
        case .richText(_, let plain):
            String(plain.prefix(200))
        case .url(let url):
            url.absoluteString
        case .image(_, let size):
            "Image — \(Int(size.width))×\(Int(size.height))"
        }
    }

    init(
        id: UUID = UUID(),
        content: ClipboardContent,
        contentType: ContentType,
        sourceAppName: String? = nil,
        sourceAppBundleID: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.content = content
        self.contentType = contentType
        self.sourceAppName = sourceAppName
        self.sourceAppBundleID = sourceAppBundleID
        self.timestamp = Date()
        self.isPinned = isPinned
    }
}

enum ClipboardContent: Sendable {
    case text(String)
    case richText(Data, String) // RTF data + plain text fallback
    case url(URL)
    case image(Data, CGSize) // image data + dimensions
}

enum HexColorParser {
    private static let pattern = try! NSRegularExpression(
        pattern: "#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})\\b"
    )

    static func firstColor(in text: String) -> NSColor? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        return parse(String(text[matchRange]))
    }

    static func parse(_ hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard h.hasPrefix("#") else { return nil }
        h.removeFirst()

        // Expand 3-char shorthand (#f0a -> #ff00aa)
        if h.count == 3 {
            h = h.map { "\($0)\($0)" }.joined()
        }
        guard h.count == 6, let value = UInt64(h, radix: 16) else { return nil }

        return NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
