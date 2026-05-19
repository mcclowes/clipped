import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Tuning constants for the on-device summarizer.
enum SummarizerConstants {
    /// Minimum character count before the Summarize action is offered. Short clips
    /// don't benefit from summarization and waste a model round-trip.
    static let minimumInputLength = 280

    /// Upper bound on the generated summary so the popover stays compact.
    static let maximumResponseTokens = 500
}

/// Failures surfaced to the UI when an on-device summarization run cannot complete.
enum SummarizerError: LocalizedError, Equatable {
    /// macOS is older than 26 — the `FoundationModels` framework isn't present.
    case unsupportedOS
    /// The OS is recent enough but the model itself can't run (Intel Mac, Apple
    /// Intelligence disabled, model still downloading). Carries the raw reason.
    case modelUnavailable(String)
    /// The model ran but produced nothing usable.
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            "Summarization needs macOS 26 or later."
        case let .modelUnavailable(reason):
            "On-device model unavailable (\(reason))."
        case .emptyResponse:
            "The model returned an empty summary."
        }
    }
}

/// On-device text summarization backed by Apple Intelligence's `FoundationModels`
/// framework. Stateless — exposed as a namespace because there is nothing to retain
/// between calls. Mirrors the `local-ai-test` prototype, adapted to Clipped's
/// conventions (see issue #73).
///
/// The framework only exists on macOS 26+, so every model touch is double-gated:
/// `#if canImport(FoundationModels)` for compile-time and `#available(macOS 26, *)`
/// for runtime. Clipped keeps its 15.0 deployment target — Sequoia users simply
/// never see the Summarize action.
@MainActor
enum Summarizer {
    /// True when on-device summarization can run right now: macOS 26+, Apple
    /// Silicon, Apple Intelligence enabled, and the model downloaded.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
            guard #available(macOS 26, *) else { return false }
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
            return false
        #else
            return false
        #endif
    }

    /// Whether `item` is the kind of clip worth summarizing — long-enough text that
    /// isn't masked as sensitive. Pure and synchronous so it can gate menu items
    /// cheaply and be unit-tested without the model.
    static func canSummarize(_ item: ClipboardItem) -> Bool {
        guard !item.isSensitive, !item.containsSecret else { return false }
        switch item.content {
        case let .text(string):
            return string.count >= SummarizerConstants.minimumInputLength
        case let .richText(_, plain):
            return plain.count >= SummarizerConstants.minimumInputLength
        default:
            return false
        }
    }

    /// Generates a concise summary of `text` on-device.
    /// - Throws: `SummarizerError` when the model is unavailable or returns nothing.
    static func summarize(_ text: String) async throws -> String {
        #if canImport(FoundationModels)
            guard #available(macOS 26, *) else {
                throw SummarizerError.unsupportedOS
            }

            let model = SystemLanguageModel.default
            guard case .available = model.availability else {
                throw SummarizerError.modelUnavailable(String(describing: model.availability))
            }

            let session = LanguageModelSession {
                """
                Summarize the following text in a few concise sentences.
                Capture only the key points. No preamble, no fluff.
                """
            }

            let response = try await session.respond(
                options: .init(maximumResponseTokens: SummarizerConstants.maximumResponseTokens)
            ) {
                text
            }

            let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else {
                throw SummarizerError.emptyResponse
            }
            return summary
        #else
            throw SummarizerError.unsupportedOS
        #endif
    }
}
