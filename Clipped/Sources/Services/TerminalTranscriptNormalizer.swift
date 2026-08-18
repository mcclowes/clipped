import Foundation

/// Prepares text copied from a terminal for soft-wrap unwrapping. Agent CLIs such as
/// Claude Code and Codex hard-wrap their prose to the terminal width and indent every
/// continuation line under a marker (`⏺ `, `• `, `- `, `1. `), so a naive unwrapper sees
/// leading whitespace on every line and refuses to touch it. This resolves those hanging
/// indents into explicit "continues previous line" flags, strips Claude Code chrome, and
/// keeps tool-output blocks (`⎿`) verbatim.
enum TerminalTranscriptNormalizer {
    struct Line: Equatable {
        var text: String
        /// The line is the wrapped tail of the previous line and should be joined to it.
        var continuesPrevious = false
        /// The line belongs to a verbatim block whose breaks must be kept.
        var isVerbatim = false
    }

    struct Result {
        var lines: [Line]
        /// True when Claude Code chrome was found, i.e. this is an agent transcript rather
        /// than arbitrary terminal output.
        var isTranscript: Bool
    }

    private struct Marker {
        var prefixLength: Int
        var isChrome: Bool
        var isVerbatim: Bool
    }

    private static let chromeMarkers: Set<Character> = ["⏺", "⎿"]
    private static let verbatimMarkers: Set<Character> = ["⎿"]
    private static let bulletMarkers: Set<Character> = ["-", "*", "+", "•", "●", "○", "◦", "▪", "›", "❯"]

    static func normalize(_ rawLines: [String]) -> Result {
        let lines = dedent(rawLines)
        var stack: [(column: Int, verbatim: Bool)] = []
        var out: [Line] = []
        var isTranscript = false

        for raw in lines {
            let indent = raw.prefix { $0 == " " }.count
            let rest = String(raw.dropFirst(indent))
            guard !rest.isEmpty else {
                out.append(Line(text: ""))
                continue
            }

            while let top = stack.last, top.column > indent {
                stack.removeLast()
            }
            let base = stack.last?.column ?? 0
            let relativeIndent = String(repeating: " ", count: indent - base)

            if let marker = marker(in: rest) {
                isTranscript = isTranscript || marker.isChrome
                let body = marker.isChrome ? String(rest.dropFirst(marker.prefixLength)) : rest
                out.append(Line(text: relativeIndent + body, isVerbatim: marker.isVerbatim))
                stack.append((indent + marker.prefixLength, marker.isVerbatim))
            } else if let top = stack.last, top.column == indent {
                out.append(Line(text: rest, continuesPrevious: !top.verbatim, isVerbatim: top.verbatim))
            } else {
                out.append(Line(text: relativeIndent + rest, isVerbatim: stack.last?.verbatim ?? false))
            }
        }

        return Result(lines: out, isTranscript: isTranscript)
    }

    /// Strips the indent shared by every non-empty line. A first line with no indent is
    /// ignored when computing it, since an upstream trim will already have eaten its
    /// leading spaces when the selection started mid-message.
    private static func dedent(_ lines: [String]) -> [String] {
        let nonEmpty = lines.enumerated().filter { !$0.element.isEmpty }
        guard !nonEmpty.isEmpty else { return lines }

        var candidates = nonEmpty
        if let first = candidates.first, first.offset == 0, first.element.first != " ",
           marker(in: first.element) == nil, candidates.count > 1
        {
            candidates.removeFirst()
        }
        let common = candidates.map { $0.element.prefix { $0 == " " }.count }.min() ?? 0
        guard common > 0 else { return lines }

        return lines.map { line in
            line.count >= common && line.prefix(common).allSatisfy { $0 == " " }
                ? String(line.dropFirst(common))
                : line
        }
    }

    private static func marker(in text: String) -> Marker? {
        guard let first = text.first else { return nil }

        func trailingSpaces(after count: Int) -> Int? {
            let spaces = text.dropFirst(count).prefix { $0 == " " }.count
            let atEnd = text.count == count
            return spaces > 0 || atEnd ? spaces : nil
        }

        if chromeMarkers.contains(first), let spaces = trailingSpaces(after: 1) {
            return Marker(prefixLength: 1 + spaces, isChrome: true, isVerbatim: verbatimMarkers.contains(first))
        }
        if bulletMarkers.contains(first), let spaces = trailingSpaces(after: 1), spaces > 0 {
            return Marker(prefixLength: 1 + spaces, isChrome: false, isVerbatim: false)
        }

        let digits = text.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count < 4 {
            let afterDigits = text.dropFirst(digits.count)
            if let punct = afterDigits.first, punct == "." || punct == ")",
               let spaces = trailingSpaces(after: digits.count + 1), spaces > 0
            {
                return Marker(prefixLength: digits.count + 1 + spaces, isChrome: false, isVerbatim: false)
            }
        }
        return nil
    }
}
