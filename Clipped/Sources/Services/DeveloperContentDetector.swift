import Foundation

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

        if uuidPattern.firstMatch(in: text, range: range) != nil {
            return true
        }
        if codeBlockPattern.firstMatch(in: text, range: range) != nil {
            return true
        }
        if hexStringPattern.firstMatch(in: text, range: range) != nil {
            return true
        }
        if jwtPattern.firstMatch(in: text, range: range) != nil {
            return true
        }
        if filePathPattern.firstMatch(in: text, range: range) != nil {
            return true
        }

        // JSON object or array
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
        else { return false }
        return trimmed.contains(":") || trimmed.contains(",")
    }
}
