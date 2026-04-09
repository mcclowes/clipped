import Foundation
import os

/// Defines a single clipboard content mutation.
@MainActor
protocol ClipboardMutation {
    var name: String { get }
    var isEnabled: Bool { get }
    func mutate(_ item: ClipboardItem) -> ClipboardItem
}

/// Protocol for the mutation pipeline, enabling DI and testing.
@MainActor
protocol ClipboardMutating {
    func apply(to item: ClipboardItem) -> ClipboardItem
}

/// Runs clipboard items through a pipeline of configurable mutations.
@MainActor
final class ClipboardMutationService: ClipboardMutating {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "ClipboardMutationService")

    let mutations: [any ClipboardMutation]

    init(mutations: [any ClipboardMutation] = ClipboardMutationService.defaultMutations()) {
        self.mutations = mutations
    }

    func apply(to item: ClipboardItem) -> ClipboardItem {
        var result = item
        for mutation in mutations where mutation.isEnabled {
            let previous = result
            result = mutation.mutate(result)
            if result !== previous {
                Self.logger.debug("Mutation '\(mutation.name)' modified item")
            }
        }
        return result
    }

    static func defaultMutations() -> [any ClipboardMutation] {
        [
            StripTrackingParamsMutation(),
            TrimWhitespaceMutation(),
        ]
    }
}

// MARK: - Built-in mutations

/// Strips common tracking parameters from URLs (utm_*, fbclid, gclid, etc.)
@MainActor
final class StripTrackingParamsMutation: ClipboardMutation {
    let name = "Strip tracking parameters"
    var isEnabled = true

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

        return ClipboardItem(
            id: item.id,
            content: .url(cleanedURL),
            contentType: item.contentType,
            sourceAppName: item.sourceAppName,
            sourceAppBundleID: item.sourceAppBundleID,
            timestamp: item.timestamp,
            isPinned: item.isPinned,
            isSensitive: item.isSensitive
        )
    }
}

/// Trims leading/trailing whitespace from plain text items.
@MainActor
final class TrimWhitespaceMutation: ClipboardMutation {
    let name = "Trim whitespace"
    var isEnabled = true

    func mutate(_ item: ClipboardItem) -> ClipboardItem {
        guard case let .text(string) = item.content else { return item }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != string else { return item }

        return ClipboardItem(
            id: item.id,
            content: .text(trimmed),
            contentType: item.contentType,
            sourceAppName: item.sourceAppName,
            sourceAppBundleID: item.sourceAppBundleID,
            timestamp: item.timestamp,
            isPinned: item.isPinned,
            isSensitive: item.isSensitive
        )
    }
}
