import AppKit
import Foundation

enum ContentType: String, CaseIterable, Identifiable {
    case plainText = "Text"
    case richText = "Rich Text"
    case url = "URL"
    case code = "Code"
    case image = "Image"

    var id: String {
        rawValue
    }

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

/// Filter options for the clipboard panel, including content types and the developer meta-filter.
enum ClipboardFilter: Hashable, Identifiable {
    case contentType(ContentType)
    case developer

    var id: String {
        switch self {
        case let .contentType(type): type.rawValue
        case .developer: "Developer"
        }
    }

    var label: String {
        switch self {
        case let .contentType(type): type.rawValue
        case .developer: "Dev"
        }
    }

    var systemImage: String {
        switch self {
        case let .contentType(type): type.systemImage
        case .developer: "curlybraces"
        }
    }
}

/// Detects developer-oriented content in plain text: UUIDs, code blocks, JSON, hashes, JWTs, file paths.
enum DeveloperContentDetector {
    // UUID: 8-4-4-4-12 hex digits
    // swiftlint:disable:next force_try
    private static let uuidPattern = try! NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    )

    // Markdown fenced code block
    // swiftlint:disable:next force_try
    private static let codeBlockPattern = try! NSRegularExpression(
        pattern: "```[\\s\\S]*?```",
        options: [.dotMatchesLineSeparators]
    )

    // Long hex strings — SHA hashes, API keys (32+ hex chars)
    // swiftlint:disable:next force_try
    private static let hexStringPattern = try! NSRegularExpression(
        pattern: "\\b[0-9a-fA-F]{32,}\\b"
    )

    // JWT tokens: three base64url segments separated by dots
    // swiftlint:disable:next force_try
    private static let jwtPattern = try! NSRegularExpression(
        pattern: "eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"
    )

    // Absolute Unix file paths (at least two segments)
    // swiftlint:disable:next force_try
    private static let filePathPattern = try! NSRegularExpression(
        pattern: "(?:^|\\s)(?:/[\\w.@-]+){2,}"
    )

    static func isDeveloperContent(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)

        if uuidPattern.firstMatch(in: text, range: range) != nil { return true }
        if codeBlockPattern.firstMatch(in: text, range: range) != nil { return true }
        if hexStringPattern.firstMatch(in: text, range: range) != nil { return true }
        if jwtPattern.firstMatch(in: text, range: range) != nil { return true }
        if filePathPattern.firstMatch(in: text, range: range) != nil { return true }

        // JSON object or array
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
        {
            if trimmed.contains(":") || trimmed.contains(",") { return true }
        }

        return false
    }
}

@MainActor
final class ClipboardItem: Identifiable {
    let id: UUID
    var content: ClipboardContent
    let contentType: ContentType
    let sourceAppName: String?
    let sourceAppBundleID: String?
    let timestamp: Date
    var isPinned: Bool
    var isSensitive: Bool
    var isDeveloperContent: Bool
    var linkTitle: String?
    var linkFavicon: Data?
    var originalContent: ClipboardContent?
    var mutationsApplied: [String] = []

    var wasMutated: Bool {
        !mutationsApplied.isEmpty
    }

    var plainText: String? {
        switch content {
        case let .text(string): string
        case let .richText(_, plainFallback): plainFallback
        case let .url(url): url.absoluteString
        default: nil
        }
    }

    var preview: String {
        switch content {
        case let .text(string):
            String(string.prefix(200))
        case let .richText(_, plain):
            String(plain.prefix(200))
        case let .url(url):
            url.absoluteString
        case let .image(_, size):
            "Image — \(Int(size.width))×\(Int(size.height))"
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
        isDeveloperContent: Bool = false
    ) {
        self.id = id
        self.content = content
        self.contentType = contentType
        self.sourceAppName = sourceAppName
        self.sourceAppBundleID = sourceAppBundleID
        self.timestamp = timestamp
        self.isPinned = isPinned
        self.isSensitive = isSensitive
        self.isDeveloperContent = isDeveloperContent
    }
}

enum ClipboardContent: Equatable {
    case text(String)
    case richText(Data, String) // RTF data + plain text fallback
    case url(URL)
    case image(Data, CGSize) // image data + dimensions
}

enum HexColorParser {
    // swiftlint:disable:next force_try
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
