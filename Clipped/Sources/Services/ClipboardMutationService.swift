import AppKit
import Foundation
import os

/// Identifies a mutation by a stable key for settings persistence.
enum MutationID: String, CaseIterable, Identifiable {
    case stripTrackingParams
    case trimWhitespace
    case cleanAmazonLinks
    case smartQuotesToStraight
    case collapseMultipleSpaces
    case stripToPlainText
    case convertToMarkdown
    case stripANSICodes
    case detectCodeSnippets

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .stripTrackingParams: "Strip tracking parameters"
        case .trimWhitespace: "Trim whitespace"
        case .cleanAmazonLinks: "Clean Amazon links"
        case .smartQuotesToStraight: "Smart quotes to straight"
        case .collapseMultipleSpaces: "Collapse multiple spaces"
        case .stripToPlainText: "Strip to plain text"
        case .convertToMarkdown: "Convert to markdown"
        case .stripANSICodes: "Strip ANSI codes"
        case .detectCodeSnippets: "Detect code snippets"
        }
    }

    var description: String {
        switch self {
        case .stripTrackingParams:
            "Removes utm_source, fbclid, gclid, and other tracking query parameters from URLs."
        case .trimWhitespace:
            "Removes leading and trailing whitespace and newlines from copied text."
        case .cleanAmazonLinks:
            "Shortens Amazon product URLs to just the /dp/ASIN path, removing referral tags."
        case .smartQuotesToStraight:
            "Converts curly \u{201C}smart\u{201D} quotes to straight \"plain\" quotes."
        case .collapseMultipleSpaces:
            "Replaces runs of multiple spaces with a single space."
        case .stripToPlainText:
            "Removes rich text formatting, keeping only the plain text content."
        case .convertToMarkdown:
            "Converts rich text (RTF) to markdown formatting."
        case .stripANSICodes:
            "Removes terminal color and formatting escape codes from copied text."
        case .detectCodeSnippets:
            "Identifies code snippets and tags them as developer content for filtering."
        }
    }

    /// Content types this mutation applies to by default.
    var defaultContentTypes: Set<ContentType> {
        switch self {
        case .stripTrackingParams: [.url]
        case .trimWhitespace: [.plainText]
        case .cleanAmazonLinks: [.url]
        case .smartQuotesToStraight: [.plainText]
        case .collapseMultipleSpaces: [.plainText]
        case .stripToPlainText: [.richText]
        case .convertToMarkdown: [.richText]
        case .stripANSICodes: [.plainText]
        case .detectCodeSnippets: [.plainText]
        }
    }

    /// Whether this mutation is enabled by default.
    var enabledByDefault: Bool {
        switch self {
        case .stripTrackingParams: true
        case .trimWhitespace: true
        case .cleanAmazonLinks: false
        case .smartQuotesToStraight: false
        case .collapseMultipleSpaces: false
        case .stripToPlainText: false
        case .convertToMarkdown: false
        case .stripANSICodes: false
        case .detectCodeSnippets: false
        }
    }
}

/// Defines a single clipboard content mutation.
@MainActor
protocol ClipboardMutation {
    var id: MutationID { get }
    var name: String { get }
    func mutate(_ item: ClipboardItem) -> ClipboardItem
}

/// Protocol for the mutation pipeline, enabling DI and testing.
@MainActor
protocol ClipboardMutating {
    func apply(to item: ClipboardItem, sourceAppBundleID: String?) -> ClipboardItem
}

/// Persisted configuration for which mutations are enabled per content type and source app.
@MainActor
protocol MutationRulesProviding {
    func isEnabled(_ mutationID: MutationID, for contentType: ContentType) -> Bool
    func isOverridden(_ mutationID: MutationID, for bundleID: String) -> Bool?
}

/// Runs clipboard items through a pipeline of configurable mutations.
@MainActor
final class ClipboardMutationService: ClipboardMutating {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "ClipboardMutationService")

    let mutations: [any ClipboardMutation]
    var rulesProvider: (any MutationRulesProviding)?

    init(mutations: [any ClipboardMutation] = ClipboardMutationService.defaultMutations()) {
        self.mutations = mutations
    }

    func apply(to item: ClipboardItem, sourceAppBundleID: String? = nil) -> ClipboardItem {
        var result = item
        var applied: [String] = []

        for mutation in mutations {
            // Check content type rule
            let enabledForType: Bool = if let rules = rulesProvider {
                rules.isEnabled(mutation.id, for: item.contentType)
            } else {
                mutation.id.defaultContentTypes.contains(item.contentType)
                    && mutation.id.enabledByDefault
            }

            // Check source app override (if any)
            var enabled = enabledForType
            if let bundleID = sourceAppBundleID, let rules = rulesProvider,
               let override = rules.isOverridden(mutation.id, for: bundleID)
            {
                enabled = override
            }

            guard enabled else { continue }

            let previous = result
            result = mutation.mutate(result)
            if result !== previous {
                applied.append(mutation.name)
                Self.logger.debug("Mutation '\(mutation.name)' modified item")
            }
        }

        if !applied.isEmpty {
            result.originalContent = item.content
            result.mutationsApplied = applied
        }

        return result
    }

    static func defaultMutations() -> [any ClipboardMutation] {
        [
            StripTrackingParamsMutation(),
            CleanAmazonLinksMutation(),
            TrimWhitespaceMutation(),
            SmartQuotesToStraightMutation(),
            CollapseMultipleSpacesMutation(),
            StripToPlainTextMutation(),
            ConvertToMarkdownMutation(),
            StripANSICodesMutation(),
            DetectCodeSnippetMutation(),
        ]
    }
}

// MARK: - Built-in mutations

/// Helper to create a new ClipboardItem preserving *all* metadata. Never drop fields here —
/// a mutation should only ever change `content`, never strip developer tagging, link previews,
/// prior mutation history, or similar.
@MainActor
private func copyItem(
    _ item: ClipboardItem,
    content: ClipboardContent
) -> ClipboardItem {
    let copy = ClipboardItem(
        id: item.id,
        content: content,
        contentType: item.contentType,
        sourceAppName: item.sourceAppName,
        sourceAppBundleID: item.sourceAppBundleID,
        timestamp: item.timestamp,
        isPinned: item.isPinned,
        isSensitive: item.isSensitive,
        isDeveloperContent: item.isDeveloperContent,
        detectedCategories: item.detectedCategories
    )
    copy.linkTitle = item.linkTitle
    copy.linkFavicon = item.linkFavicon
    copy.originalContent = item.originalContent
    copy.mutationsApplied = item.mutationsApplied
    copy.customPasteboardTypes = item.customPasteboardTypes
    return copy
}

/// Strips common tracking parameters from URLs (utm_*, fbclid, gclid, etc.)
@MainActor
final class StripTrackingParamsMutation: ClipboardMutation {
    let id = MutationID.stripTrackingParams
    let name = "Stripped tracking parameters"

    private static let trackingParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "fbclid", "gclid", "gclsrc", "dclid", "msclkid",
        "mc_cid", "mc_eid", "oly_enc_id", "oly_anon_id",
        "_hsenc", "_hsmi", "hsCtaTracking",
        "vero_id", "vero_conv",
        "s_cid", "icid",
        "ref", "ref_src", "ref_url",
    ]

    func mutate(_ item: ClipboardItem) -> ClipboardItem {
        guard case let .url(url) = item.content,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty
        else { return item }

        let cleaned = queryItems.filter { queryItem in
            !Self.trackingParams.contains(queryItem.name.lowercased())
        }

        if cleaned.count == queryItems.count { return item }

        components.queryItems = cleaned.isEmpty ? nil : cleaned

        guard let cleanedURL = components.url else { return item }

        return copyItem(item, content: .url(cleanedURL))
    }
}

/// Trims leading/trailing whitespace from plain text items.
@MainActor
final class TrimWhitespaceMutation: ClipboardMutation {
    let id = MutationID.trimWhitespace
    let name = "Trimmed whitespace"

    func mutate(_ item: ClipboardItem) -> ClipboardItem {
        guard case let .text(string) = item.content else { return item }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != string else { return item }

        return copyItem(item, content: .text(trimmed))
    }
}

/// Cleans Amazon product URLs to just the /dp/ASIN path.
@MainActor
final class CleanAmazonLinksMutation: ClipboardMutation {
    let id = MutationID.cleanAmazonLinks
    let name = "Cleaned Amazon link"

    // swiftlint:disable:next force_try
    private static let dpPattern = try! NSRegularExpression(
        pattern: "/dp/([A-Z0-9]{10})"
    )

    private static let amazonHosts: Set<String> = [
        "amazon.com", "www.amazon.com",
        "amazon.co.uk", "www.amazon.co.uk",
        "amazon.de", "www.amazon.de",
        "amazon.fr", "www.amazon.fr",
        "amazon.ca", "www.amazon.ca",
        "amazon.co.jp", "www.amazon.co.jp",
        "amazon.com.au", "www.amazon.com.au",
        "amazon.it", "www.amazon.it",
        "amazon.es", "www.amazon.es",
        "amazon.in", "www.amazon.in",
    ]

    func mutate(_ item: ClipboardItem) -> ClipboardItem {
        guard case let .url(url) = item.content,
              let host = url.host?.lowercased(),
              Self.amazonHosts.contains(host)
        else { return item }

        let path = url.path
        let range = NSRange(path.startIndex..., in: path)
        guard let match = Self.dpPattern.firstMatch(in: path, range: range),
              let asinRange = Range(match.range(at: 1), in: path)
        else { return item }

        let asin = String(path[asinRange])
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.path = "/dp/\(asin)"

        guard let cleanedURL = components.url else { return item }
        guard cleanedURL != url else { return item }

        return copyItem(item, content: .url(cleanedURL))
    }
}

/// Converts smart (curly) quotes to straight quotes.
@MainActor
final class SmartQuotesToStraightMutation: ClipboardMutation {
    let id = MutationID.smartQuotesToStraight
    let name = "Straightened quotes"

    func mutate(_ item: ClipboardItem) -> ClipboardItem {
        guard case let .text(string) = item.content else { return item }

        // Single-pass replacement; avoids the O(n) allocations per replacement rule
        // that the previous implementation produced.
        var didChange = false
        let mapped = string.map { (char: Character) -> Character in
            switch char {
            case "\u{2018}", "\u{2019}":
                didChange = true
                return "'"
            case "\u{201C}", "\u{201D}":
                didChange = true
                return "\""
            default:
                return char
            }
        }

        guard didChange else { return item }

        return copyItem(item, content: .text(String(mapped)))
    }
}

/// Collapses runs of multiple spaces into a single space.
@MainActor
final class CollapseMultipleSpacesMutation: ClipboardMutation {
    let id = MutationID.collapseMultipleSpaces
    let name = "Collapsed multiple spaces"

    // swiftlint:disable:next force_try
    private static let multiSpacePattern = try! NSRegularExpression(
        pattern: " {2,}"
    )

    func mutate(_ item: ClipboardItem) -> ClipboardItem {
        guard case let .text(string) = item.content else { return item }

        let range = NSRange(string.startIndex..., in: string)
        let collapsed = Self.multiSpacePattern.stringByReplacingMatches(
            in: string,
            range: range,
            withTemplate: " "
        )

        guard collapsed != string else { return item }

        return copyItem(item, content: .text(collapsed))
    }
}

/// Strips rich text formatting, keeping only the plain text fallback.
@MainActor
final class StripToPlainTextMutation: ClipboardMutation {
    let id = MutationID.stripToPlainText
    let name = "Stripped to plain text"

    func mutate(_ item: ClipboardItem) -> ClipboardItem {
        guard case let .richText(_, plainFallback) = item.content else { return item }
        // Note: we no longer guard on !plainFallback.isEmpty. Stripping formatting from
        // rich text with no plain-text fallback is a valid (if unusual) result.
        return copyItem(item, content: .text(plainFallback))
    }
}

/// Converts rich text (RTF) to markdown using the existing MarkdownConverter.
@MainActor
final class ConvertToMarkdownMutation: ClipboardMutation {
    let id = MutationID.convertToMarkdown
    let name = "Converted to markdown"

    func mutate(_ item: ClipboardItem) -> ClipboardItem {
        guard case let .richText(rtfData, plainFallback) = item.content,
              let markdown = MarkdownConverter.convert(rtfData: rtfData),
              !markdown.isEmpty,
              markdown != plainFallback
        else { return item }

        return copyItem(item, content: .text(markdown))
    }
}

/// Strips ANSI escape codes from text (common in terminal output).
@MainActor
final class StripANSICodesMutation: ClipboardMutation {
    let id = MutationID.stripANSICodes
    let name = "Stripped ANSI codes"

    // Matches ANSI CSI sequences: ESC[ followed by params and a final byte
    // swiftlint:disable:next force_try
    private static let ansiPattern = try! NSRegularExpression(
        pattern: "\\x1B\\[[0-9;]*[A-Za-z]"
    )

    func mutate(_ item: ClipboardItem) -> ClipboardItem {
        guard case let .text(string) = item.content else { return item }

        let range = NSRange(string.startIndex..., in: string)
        let stripped = Self.ansiPattern.stringByReplacingMatches(
            in: string,
            range: range,
            withTemplate: ""
        )

        guard stripped != string else { return item }

        return copyItem(item, content: .text(stripped))
    }
}

/// Detects code snippets in plain text and reclassifies as `.code` with `isDeveloperContent`.
@MainActor
final class DetectCodeSnippetMutation: ClipboardMutation {
    let id = MutationID.detectCodeSnippets
    let name = "Detected code snippet"

    // Import/include statements
    // swiftlint:disable:next force_try
    private static let importPattern = try! NSRegularExpression(
        pattern: #"(?m)^(?:import\s|from\s+\S+\s+import\s|#include\s|using\s+\S+;|require\()"#
    )

    // Function/method declarations
    // swiftlint:disable:next force_try
    private static let declarationPattern = try! NSRegularExpression(
        pattern: #"(?m)^(?:(?:export\s+)?(?:async\s+)?function\s+\w+|def\s+\w+\s*\(|(?:pub\s+)?fn\s+\w+|func\s+\w+)"#
    )

    // Variable declarations (let/const/var with assignment)
    // swiftlint:disable:next force_try
    private static let variablePattern = try! NSRegularExpression(
        pattern: #"(?m)^(?:(?:export\s+)?(?:const|let|var)\s+\w+\s*[=:])"#
    )

    // Arrow functions
    // swiftlint:disable:next force_try
    private static let arrowPattern = try! NSRegularExpression(
        pattern: #"=>\s*[{\(]|=>\s*\w"#
    )

    // Class/struct/enum/interface declarations
    // swiftlint:disable:next force_try
    private static let classPattern = try! NSRegularExpression(
        pattern: #"(?m)^(?:(?:export\s+)?(?:abstract\s+)?class\s+\w+|struct\s+\w+|enum\s+\w+|interface\s+\w+|protocol\s+\w+)"#
    )

    // Shell commands (common package managers, git, etc.)
    // swiftlint:disable:next force_try
    private static let shellPattern = try! NSRegularExpression(
        pattern: #"(?m)^(?:npm\s+(?:install|run|start|test|build)|pip\s+install|yarn\s+(?:add|run)|pnpm\s+(?:add|run)|git\s+(?:commit|push|pull|checkout|merge|rebase|clone|stash)|brew\s+install|cargo\s+(?:build|run|test)|docker\s+(?:run|build|compose)|kubectl\s+|curl\s+-)"#
    )

    // Code density: lines ending with ; or { or } (need 2+ to trigger)
    // swiftlint:disable:next force_try
    private static let braceOrSemicolonLine = try! NSRegularExpression(
        pattern: #"(?m)[;{}\)]$"#
    )

    // require() as used in JS/Node (not at line start, e.g. `const x = require('y')`)
    // swiftlint:disable:next force_try
    private static let requireCallPattern = try! NSRegularExpression(
        pattern: #"=\s*require\(['"]\w"#
    )

    func mutate(_ item: ClipboardItem) -> ClipboardItem {
        guard case let .text(string) = item.content,
              item.contentType == .plainText,
              !item.isDeveloperContent
        else { return item }

        guard looksLikeCode(string) else { return item }

        // Flip the flag on a metadata-preserving copy. We keep the *same* content so we
        // round-trip through the normal copy helper and preserve linkTitle/favicon/etc.
        let copy = copyItem(item, content: item.content)
        copy.isDeveloperContent = true
        return copy
    }

    private func looksLikeCode(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)

        // Single-pattern matches (high confidence)
        if Self.importPattern.firstMatch(in: text, range: range) != nil { return true }
        if Self.declarationPattern.firstMatch(in: text, range: range) != nil { return true }
        if Self.variablePattern.firstMatch(in: text, range: range) != nil { return true }
        if Self.arrowPattern.firstMatch(in: text, range: range) != nil { return true }
        if Self.classPattern.firstMatch(in: text, range: range) != nil { return true }
        if Self.shellPattern.firstMatch(in: text, range: range) != nil { return true }
        if Self.requireCallPattern.firstMatch(in: text, range: range) != nil { return true }

        // Code density: 2+ lines ending with braces/semicolons
        let braceMatches = Self.braceOrSemicolonLine.numberOfMatches(in: text, range: range)
        if braceMatches >= 2 { return true }

        return false
    }
}
