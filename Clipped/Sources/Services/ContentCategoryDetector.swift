import AppKit
import Foundation

/// Detects lightweight content categories (email, phone, color, number) in plain text.
/// These run in addition to the developer-content detector and produce a set so that
/// an item can fall into multiple categories at once.
enum ContentCategoryDetector {
    static func detect(in text: String) -> Set<ContentCategory> {
        var results: Set<ContentCategory> = []
        if EmailDetector.contains(text) {
            results.insert(.email)
        }
        if PhoneNumberDetector.contains(text) {
            results.insert(.phoneNumber)
        }
        if HexColorParser.firstColor(in: text) != nil {
            results.insert(.hexColor)
        }
        if NumberDetector.contains(text) {
            results.insert(.number)
        }
        if IPAddressDetector.contains(text) {
            results.insert(.ipAddress)
        }
        if MACAddressDetector.contains(text) {
            results.insert(.macAddress)
        }
        return results
    }
}

/// Detects dotted-quad IPv4 addresses. Each octet is validated to 0–255 so partial
/// matches like "999.1.1.1" don't register. IPv6 is intentionally out of scope: its
/// grammar is too permissive to match without frequent false positives.
enum IPAddressDetector {
    // swiftlint:disable:next force_try
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b"#
    )

    static func contains(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.firstMatch(in: text, range: range) != nil
    }
}

/// Detects hardware (MAC) addresses: six hex octets joined by a consistent `:` or `-`
/// separator. Mixed separators are rejected since no real MAC notation uses them.
enum MACAddressDetector {
    // swiftlint:disable:next force_try
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b|\b(?:[0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}\b"#
    )

    static func contains(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.firstMatch(in: text, range: range) != nil
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
    /// NSDataDetector handles international formats, separators, and extensions for free.
    /// It occasionally matches long digit runs, so we also require at least 7 digits to
    /// rule out things like short order numbers.
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
        if currencyPattern.firstMatch(in: text, range: range) != nil {
            return true
        }
        if percentPattern.firstMatch(in: text, range: range) != nil {
            return true
        }
        if thousandsPattern.firstMatch(in: text, range: range) != nil {
            return true
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRange = NSRange(trimmed.startIndex..., in: trimmed)
        if bareNumberPattern.firstMatch(in: trimmed, range: trimmedRange) != nil {
            return true
        }

        return false
    }
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
