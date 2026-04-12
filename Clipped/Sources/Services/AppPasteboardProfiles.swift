import AppKit
import Foundation

/// A profile describing how to handle clipboard content from a specific app that uses
/// custom pasteboard types (e.g. Logic Pro regions, Sketch layers). These apps put an
/// opaque plain-text preview on the pasteboard plus one or more custom UTIs — paste
/// only works if the custom UTIs are preserved, which we wouldn't do by default.
struct AppPasteboardProfile {
    let bundleIDs: Set<String>
    let displayAppName: String
    let kindLabel: String
    /// Build a human-legible preview from the raw plain-text representation the app
    /// wrote to the pasteboard. Returns `nil` if the string doesn't look like content
    /// from this app after all.
    let prettyPreview: @Sendable (String) -> String?
}

enum AppPasteboardProfiles {
    static let all: [AppPasteboardProfile] = [logicPro]

    /// Logic Pro writes regions/tracks to the pasteboard in a bar/beat format like:
    ///   "1 1 1 1      4 Guitar     7     149 1 1 105."
    /// The contiguous run of non-numeric tokens is the track/region name. Clipped's
    /// plain-text preview is unreadable, so we parse out the name and tag it clearly.
    static let logicPro = AppPasteboardProfile(
        bundleIDs: [
            "com.apple.logic10",
            "com.apple.logic.pro",
            "com.apple.logic.pro.trial",
        ],
        displayAppName: "Logic Pro",
        kindLabel: "region",
        prettyPreview: { raw in
            let trackName = extractTrackName(raw)
            guard !trackName.isEmpty else { return nil }
            return "Logic Pro region — \(trackName)"
        }
    )

    static func profile(for bundleID: String?) -> AppPasteboardProfile? {
        guard let bundleID else { return nil }
        return all.first { $0.bundleIDs.contains(bundleID) }
    }

    /// Extract the first contiguous run of non-numeric tokens from a whitespace-separated
    /// string. Tokens that are purely digits (with optional trailing dot) are treated as
    /// position/length markers and skipped; the first non-numeric token starts the name
    /// and subsequent non-numeric tokens extend it until a numeric token breaks the run.
    static func extractTrackName(_ raw: String) -> String {
        let tokens = raw.split(whereSeparator: \.isWhitespace)
        var collected: [Substring] = []
        var started = false
        for token in tokens {
            let core = token.hasSuffix(".") ? token.dropLast() : token
            let isNumeric = !core.isEmpty && core.allSatisfy(\.isNumber)
            if isNumeric {
                if started { break }
            } else {
                started = true
                collected.append(token)
            }
        }
        return collected.joined(separator: " ")
    }
}
