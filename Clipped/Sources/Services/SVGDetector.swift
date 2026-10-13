import Foundation

/// Lightweight detector for SVG markup copied as plain text. We intentionally stay
/// loose: anything that begins (after optional whitespace / XML / DOCTYPE prolog)
/// with an `<svg` tag is treated as SVG. Copying an HTML fragment that *contains*
/// an `<svg>` but starts with other markup will not trigger, which is the behavior
/// we want — otherwise pasting an article into the clipboard would misclassify it.
enum SVGDetector {
    private static let maxSniffCharacters = 2048

    static func looksLikeSVG(_ text: String) -> Bool {
        let trimmed = text.drop { $0.isWhitespace || $0.isNewline }
        guard let first = trimmed.first, first == "<" else { return false }

        var root = Substring(String(trimmed.prefix(maxSniffCharacters)).lowercased())
        guard root.hasPrefix("<?xml") || root.hasPrefix("<!doctype") else {
            return hasSVGRoot(root)
        }

        while root.hasPrefix("<?xml") || root.hasPrefix("<!doctype") {
            guard let end = root.firstIndex(of: ">") else { return false }
            root = root[root.index(after: end)...]
                .drop { $0.isWhitespace || $0.isNewline }
        }
        // Comments are skipped only after a prolog, preserving the existing sniffing rule.
        while root.hasPrefix("<!--") {
            guard let endRange = root.range(of: "-->") else { return false }
            root = root[endRange.upperBound...]
                .drop { $0.isWhitespace || $0.isNewline }
        }
        return hasSVGRoot(root)
    }

    private static func hasSVGRoot(_ text: Substring) -> Bool {
        text.hasPrefix("<svg>") || text.hasPrefix("<svg ") || text.hasPrefix("<svg\n")
            || text.hasPrefix("<svg\t") || text.hasPrefix("<svg/")
    }
}
