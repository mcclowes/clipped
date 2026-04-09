import Foundation
import os

/// Identifies a mutation by a stable key for settings persistence.
enum MutationID: String, CaseIterable, Identifiable {
    case stripTrackingParams
    case trimWhitespace

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .stripTrackingParams: "Strip tracking parameters"
        case .trimWhitespace: "Trim whitespace"
        }
    }

    /// Content types this mutation applies to by default.
    var defaultContentTypes: Set<ContentType> {
        switch self {
        case .stripTrackingParams: [.url]
        case .trimWhitespace: [.plainText, .code]
        }
    }

    /// Whether this mutation is enabled by default.
    var enabledByDefault: Bool {
        switch self {
        case .stripTrackingParams: true
        case .trimWhitespace: true
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
            TrimWhitespaceMutation(),
        ]
    }
}

// MARK: - Built-in mutations

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
    let id = MutationID.trimWhitespace
    let name = "Trimmed whitespace"

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
