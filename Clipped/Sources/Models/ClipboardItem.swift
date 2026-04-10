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
enum ContentCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case email
    case phoneNumber
    case hexColor
    case number

    var id: String { rawValue }

    var label: String {
        switch self {
        case .email: "Email"
        case .phoneNumber: "Phone"
        case .hexColor: "Color"
        case .number: "Number"
        }
    }

    var systemImage: String {
        switch self {
        case .email: "envelope"
        case .phoneNumber: "phone"
        case .hexColor: "paintpalette"
        case .number: "number"
        }
    }

    var settingsDescription: String {
        switch self {
        case .email: "Items containing an email address"
        case .phoneNumber: "Items containing a phone number"
        case .hexColor: "Items containing a #RRGGBB hex color"
        case .number: "Amounts, percentages, currency values"
        }
    }
}

/// Groups of source apps the user can filter by. The bundle-ID databases live here so
/// both the monitor (for tagging dev content) and the filter (for bucketing by source)
/// read from the same source of truth.
enum SourceAppCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case communication
    case browser
    case codeEditor
    case terminal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .communication: "Chat"
        case .browser: "Browser"
        case .codeEditor: "Editor"
        case .terminal: "Terminal"
        }
    }

    var systemImage: String {
        switch self {
        case .communication: "bubble.left.and.bubble.right"
        case .browser: "safari"
        case .codeEditor: "chevron.left.forwardslash.chevron.right"
        case .terminal: "terminal"
        }
    }

    var settingsDescription: String {
        switch self {
        case .communication: "Slack, Messages, Mail, Teams, Discord, Telegram\u{2026}"
        case .browser: "Safari, Chrome, Firefox, Edge, Arc\u{2026}"
        case .codeEditor: "Xcode, VS Code, Cursor, Sublime, JetBrains, Zed\u{2026}"
        case .terminal: "Terminal, iTerm2, Alacritty, kitty, WezTerm\u{2026}"
        }
    }

    var bundleIDs: Set<String> {
        switch self {
        case .communication:
            [
                "com.tinyspeck.slackmacgap", // Slack
                "com.apple.iChat", // Messages
                "com.apple.MobileSMS", // Messages (newer bundle)
                "com.apple.mail", // Mail
                "com.microsoft.teams", // Teams v1
                "com.microsoft.teams2", // Teams v2
                "com.microsoft.Outlook", // Outlook
                "com.readdle.smartemail-Mac", // Spark
                "com.hnc.Discord", // Discord
                "net.whatsapp.WhatsApp", // WhatsApp
                "ru.keepcoder.Telegram", // Telegram
                "com.tdesktop.Telegram", // Telegram Desktop
                "com.apple.FaceTime", // FaceTime
                "us.zoom.xos", // Zoom
            ]
        case .browser:
            [
                "com.apple.Safari",
                "com.apple.SafariTechnologyPreview",
                "com.google.Chrome",
                "com.google.Chrome.canary",
                "org.mozilla.firefox",
                "org.mozilla.firefoxdeveloperedition",
                "com.brave.Browser",
                "company.thebrowser.Browser", // Arc
                "com.microsoft.edgemac",
                "com.vivaldi.Vivaldi",
                "com.operasoftware.Opera",
            ]
        case .codeEditor:
            [
                "com.microsoft.VSCode",
                "com.microsoft.VSCodeInsiders",
                "com.apple.dt.Xcode",
                "com.sublimetext.4",
                "com.jetbrains.intellij",
                "com.jetbrains.pycharm",
                "com.jetbrains.WebStorm",
                "com.jetbrains.AppCode",
                "com.jetbrains.goland",
                "dev.zed.Zed",
                "com.todesktop.230313mzl4w4u92", // Cursor
                "com.github.atom",
                "com.panic.Nova",
            ]
        case .terminal:
            [
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "io.alacritty",
                "com.github.wez.wezterm",
                "net.kovidgoyal.kitty",
                "dev.warp.Warp-Stable",
            ]
        }
    }

    static func category(for bundleID: String) -> SourceAppCategory? {
        allCases.first { $0.bundleIDs.contains(bundleID) }
    }
}

/// Filter options for the clipboard panel, including content types and the developer meta-filter.
enum ClipboardFilter: Hashable, Identifiable {
    case contentType(ContentType)
    case text // combines plainText + richText
    case developer
    case category(ContentCategory)
    case sourceApp(SourceAppCategory)

    var id: String {
        switch self {
        case let .contentType(type): type.rawValue
        case .text: "Text"
        case .developer: "Developer"
        case let .category(cat): "Category.\(cat.rawValue)"
        case let .sourceApp(app): "SourceApp.\(app.rawValue)"
        }
    }

    var label: String {
        switch self {
        case let .contentType(type): type.rawValue
        case .text: "Text"
        case .developer: "Dev"
        case let .category(cat): cat.label
        case let .sourceApp(app): app.label
        }
    }

    var systemImage: String {
        switch self {
        case let .contentType(type): type.systemImage
        case .text: "doc.text"
        case .developer: "curlybraces"
        case let .category(cat): cat.systemImage
        case let .sourceApp(app): app.systemImage
        }
    }

    /// User-visible description shown in settings next to the toggle.
    var settingsDescription: String {
        switch self {
        case .text:
            "Plain and rich text items"
        case .contentType(.url):
            "Web links"
        case .contentType(.image):
            "Screenshots and other images"
        case .developer:
            "UUIDs, JSON, JWTs, hashes, code blocks, file paths"
        case .contentType(.plainText):
            "Plain text only"
        case .contentType(.richText):
            "Rich text only"
        case let .category(cat):
            cat.settingsDescription
        case let .sourceApp(app):
            app.settingsDescription
        }
    }

    /// Filter categories the user can show or hide in the panel's tab bar.
    /// "All" is implicit — it is always shown as the default selection.
    /// Composed from the three sub-groups so the ordering stays in sync with Settings.
    static var toggleableCategories: [ClipboardFilter] {
        contentTypeFilters + smartCategoryFilters + sourceAppFilters
    }

    /// IDs of filter tabs that default to hidden on first launch. Keeps the strip tidy for
    /// existing users while still letting new users discover the extended set via settings.
    static let defaultHiddenCategoryIDs: Set<String> = [
        ClipboardFilter.category(.email).id,
        ClipboardFilter.category(.phoneNumber).id,
        ClipboardFilter.category(.hexColor).id,
        ClipboardFilter.category(.number).id,
        ClipboardFilter.sourceApp(.communication).id,
        ClipboardFilter.sourceApp(.browser).id,
        ClipboardFilter.sourceApp(.codeEditor).id,
        ClipboardFilter.sourceApp(.terminal).id,
    ]

    /// Filter tabs that pivot on the clipboard item's native content type.
    static let contentTypeFilters: [ClipboardFilter] = [
        .text,
        .contentType(.url),
        .developer,
        .contentType(.image),
    ]

    /// Filter tabs powered by `ContentCategoryDetector` — free-form content pattern matches.
    static let smartCategoryFilters: [ClipboardFilter] = ContentCategory.allCases.map(ClipboardFilter.category)

    /// Filter tabs powered by `SourceAppCategory` — bucketed by where the item was copied from.
    static let sourceAppFilters: [ClipboardFilter] = SourceAppCategory.allCases.map(ClipboardFilter.sourceApp)
}

/// Detects lightweight content categories (email, phone, color, number) in plain text.
/// These run in addition to the developer-content detector and produce a set so that
/// an item can fall into multiple categories at once.
enum ContentCategoryDetector {
    static func detect(in text: String) -> Set<ContentCategory> {
        var results: Set<ContentCategory> = []
        if EmailDetector.contains(text) { results.insert(.email) }
        if PhoneNumberDetector.contains(text) { results.insert(.phoneNumber) }
        if HexColorParser.firstColor(in: text) != nil { results.insert(.hexColor) }
        if NumberDetector.contains(text) { results.insert(.number) }
        return results
    }
}

enum EmailDetector {
    // Intentionally strict on the TLD length (2+ letters) to reduce false positives on
    // things like "foo@bar" or "a@b.c".
    // swiftlint:disable:next force_try
    private static let pattern = try! NSRegularExpression(
        pattern: "\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b",
        options: .caseInsensitive
    )

    static func contains(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.firstMatch(in: text, range: range) != nil
    }
}

enum PhoneNumberDetector {
    // NSDataDetector handles international formats, separators, and extensions for free.
    // It occasionally matches long digit runs, so we also require at least 7 digits to
    // rule out things like short order numbers.
    private static let detector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
    )

    static func contains(_ text: String) -> Bool {
        guard let detector else { return false }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else { return false }
        let digitCount = text[matchRange].filter(\.isNumber).count
        return digitCount >= 7
    }
}

/// Detects numeric/currency/percent content. Favors precision over recall: only matches
/// patterns that are unambiguously "a number" so that plain sentences with digits
/// (e.g. "the year 2024") don't leak into the Number filter.
enum NumberDetector {
    // Currency symbol followed by a digit: "$100", "€50.00", "£1,234.56"
    // swiftlint:disable:next force_try
    private static let currencyPattern = try! NSRegularExpression(
        pattern: "[$€£¥₹₩₪₺฿]\\s?-?\\d"
    )

    // Digit followed by a percent sign: "50%", "12.5 %"
    // swiftlint:disable:next force_try
    private static let percentPattern = try! NSRegularExpression(
        pattern: "\\d(?:[.,]\\d+)?\\s?%"
    )

    // Thousands-separated number: "1,234", "1,234,567.89"
    // swiftlint:disable:next force_try
    private static let thousandsPattern = try! NSRegularExpression(
        pattern: "\\b\\d{1,3}(?:,\\d{3})+(?:\\.\\d+)?\\b"
    )

    // Entire trimmed text is a bare number: "420", "-3.14", "+1.5"
    // swiftlint:disable:next force_try
    private static let bareNumberPattern = try! NSRegularExpression(
        pattern: "^[-+]?\\d+(?:[.,]\\d+)?$"
    )

    static func contains(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if currencyPattern.firstMatch(in: text, range: range) != nil { return true }
        if percentPattern.firstMatch(in: text, range: range) != nil { return true }
        if thousandsPattern.firstMatch(in: text, range: range) != nil { return true }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRange = NSRange(trimmed.startIndex..., in: trimmed)
        if bareNumberPattern.firstMatch(in: trimmed, range: trimmedRange) != nil { return true }

        return false
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
@Observable
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
    var detectedCategories: Set<ContentCategory>
    var linkTitle: String?
    var linkFavicon: Data?
    var originalContent: ClipboardContent?
    var mutationsApplied: [String] = []

    /// Convenience lookup for the source app's broad category, derived from the
    /// bundle ID at access time so the classification stays consistent with any
    /// changes to `SourceAppCategory.bundleIDs`.
    var sourceAppCategory: SourceAppCategory? {
        guard let bundleID = sourceAppBundleID else { return nil }
        return SourceAppCategory.category(for: bundleID)
    }

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
        self.isDeveloperContent = isDeveloperContent
        self.detectedCategories = detectedCategories
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
