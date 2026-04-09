import Carbon
@testable import Clipped
import Foundation
import Testing

@MainActor
struct ClipboardMutationTests {
    // MARK: - StripTrackingParamsMutation

    @Test("Strips UTM parameters from URLs")
    func stripUTMParams() throws {
        let mutation = StripTrackingParamsMutation()
        let url = try #require(URL(string: "https://example.com/page?utm_source=twitter&utm_medium=social&id=123"))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        let result = mutation.mutate(item)

        guard case let .url(cleanedURL) = result.content else {
            Issue.record("Expected URL content")
            return
        }
        #expect(cleanedURL.absoluteString == "https://example.com/page?id=123")
    }

    @Test("Strips fbclid from URLs")
    func stripFbclid() throws {
        let mutation = StripTrackingParamsMutation()
        let url = try #require(URL(string: "https://example.com/?fbclid=abc123"))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        let result = mutation.mutate(item)

        guard case let .url(cleanedURL) = result.content else {
            Issue.record("Expected URL content")
            return
        }
        #expect(cleanedURL.absoluteString == "https://example.com/")
    }

    @Test("Preserves URLs without tracking params")
    func preserveCleanURLs() throws {
        let mutation = StripTrackingParamsMutation()
        let url = try #require(URL(string: "https://example.com/page?id=123&sort=date"))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        let result = mutation.mutate(item)

        #expect(result === item) // Same instance, no mutation needed
    }

    @Test("Ignores non-URL items")
    func ignoreNonURLItems() {
        let mutation = StripTrackingParamsMutation()
        let item = ClipboardItem(content: .text("hello world"), contentType: .plainText)

        let result = mutation.mutate(item)

        #expect(result === item)
    }

    // MARK: - TrimWhitespaceMutation

    @Test("Trims leading and trailing whitespace")
    func trimWhitespace() {
        let mutation = TrimWhitespaceMutation()
        let item = ClipboardItem(content: .text("  hello world  \n"), contentType: .plainText)

        let result = mutation.mutate(item)

        guard case let .text(trimmed) = result.content else {
            Issue.record("Expected text content")
            return
        }
        #expect(trimmed == "hello world")
    }

    @Test("Preserves text without extra whitespace")
    func preserveCleanText() {
        let mutation = TrimWhitespaceMutation()
        let item = ClipboardItem(content: .text("hello world"), contentType: .plainText)

        let result = mutation.mutate(item)

        #expect(result === item)
    }

    @Test("Ignores non-text items")
    func trimIgnoresURLs() throws {
        let mutation = TrimWhitespaceMutation()
        let url = try #require(URL(string: "https://example.com"))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        let result = mutation.mutate(item)

        #expect(result === item)
    }

    // MARK: - Pipeline with content type targeting

    @Test("Pipeline applies mutations matching content type")
    func pipelineContentTypeTargeting() throws {
        let service = ClipboardMutationService()
        let url = try #require(URL(string: "https://example.com/?utm_source=test"))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        let result = service.apply(to: item, sourceAppBundleID: nil)

        guard case let .url(cleanedURL) = result.content else {
            Issue.record("Expected URL content")
            return
        }
        #expect(cleanedURL.absoluteString == "https://example.com/")
    }

    @Test("Pipeline skips mutations for non-matching content type")
    func pipelineSkipsNonMatchingType() {
        let service = ClipboardMutationService()
        // TrimWhitespace targets plainText/code, not URL
        let item = ClipboardItem(content: .text("hello"), contentType: .url)

        let result = service.apply(to: item, sourceAppBundleID: nil)

        // TrimWhitespace shouldn't run because content type is .url
        #expect(result === item)
    }

    // MARK: - Mutation tracking (originalContent + mutationsApplied)

    @Test("Mutated items track original content")
    func tracksOriginalContent() throws {
        let service = ClipboardMutationService()
        let url = try #require(URL(string: "https://example.com/?utm_source=test"))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        let result = service.apply(to: item, sourceAppBundleID: nil)

        #expect(result.wasMutated)
        #expect(result.originalContent == .url(url))
        #expect(result.mutationsApplied == ["Stripped tracking parameters"])
    }

    @Test("Unmutated items have no mutation tracking")
    func noTrackingForUnmutated() throws {
        let service = ClipboardMutationService()
        let url = try #require(URL(string: "https://example.com/clean"))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        let result = service.apply(to: item, sourceAppBundleID: nil)

        #expect(!result.wasMutated)
        #expect(result.originalContent == nil)
        #expect(result.mutationsApplied.isEmpty)
    }

    @Test("Restore original reverts content")
    func restoreOriginal() throws {
        let url = try #require(URL(string: "https://example.com/?utm_source=test"))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        // Simulate mutation
        let cleanURL = try #require(URL(string: "https://example.com/"))
        item.content = .url(cleanURL)
        item.originalContent = .url(url)
        item.mutationsApplied = ["Stripped tracking parameters"]

        // Restore
        item.content = try #require(item.originalContent)
        item.originalContent = nil
        item.mutationsApplied = []

        #expect(!item.wasMutated)
        guard case let .url(restored) = item.content else {
            Issue.record("Expected URL content")
            return
        }
        #expect(restored == url)
    }

    // MARK: - Rules provider

    @Test("Rules provider controls which mutations run")
    func rulesProviderTargeting() {
        let rules = MockMutationRules()
        // Disable trimWhitespace for plainText
        rules.enabledRules["trimWhitespace:Text"] = false

        let service = ClipboardMutationService()
        service.rulesProvider = rules

        let item = ClipboardItem(content: .text("  hello  "), contentType: .plainText)
        let result = service.apply(to: item, sourceAppBundleID: nil)

        #expect(result === item) // Not mutated because rule disabled it
    }

    @Test("Source app override takes precedence")
    func sourceAppOverride() {
        let rules = MockMutationRules()
        // Enable trimWhitespace for plainText
        rules.enabledRules["trimWhitespace:Text"] = true
        // But override: disable for Xcode
        rules.appOverrides["trimWhitespace:com.apple.dt.Xcode"] = false

        let service = ClipboardMutationService()
        service.rulesProvider = rules

        let item = ClipboardItem(content: .text("  hello  "), contentType: .plainText)
        let result = service.apply(to: item, sourceAppBundleID: "com.apple.dt.Xcode")

        #expect(result === item) // Not mutated because app override disabled it
    }

    @Test("Source app override can enable a disabled mutation")
    func sourceAppOverrideEnables() {
        let rules = MockMutationRules()
        // Disable trimWhitespace for plainText
        rules.enabledRules["trimWhitespace:Text"] = false
        // But override: enable for Terminal
        rules.appOverrides["trimWhitespace:com.apple.Terminal"] = true

        let service = ClipboardMutationService()
        service.rulesProvider = rules

        let item = ClipboardItem(content: .text("  hello  "), contentType: .plainText)
        let result = service.apply(to: item, sourceAppBundleID: "com.apple.Terminal")

        #expect(result !== item) // Was mutated because app override enabled it
        #expect(result.wasMutated)
    }

    @Test("Mutation preserves item metadata")
    func preservesMetadata() throws {
        let service = ClipboardMutationService()
        let url = try #require(URL(string: "https://example.com/?utm_source=test"))
        let item = ClipboardItem(
            content: .url(url),
            contentType: .url,
            sourceAppName: "Safari",
            sourceAppBundleID: "com.apple.Safari",
            isPinned: true,
            isSensitive: true
        )

        let result = service.apply(to: item, sourceAppBundleID: nil)

        #expect(result.id == item.id)
        #expect(result.sourceAppName == "Safari")
        #expect(result.sourceAppBundleID == "com.apple.Safari")
        #expect(result.isPinned == true)
        #expect(result.isSensitive == true)
        #expect(result.contentType == .url)
    }

    // MARK: - MutationID

    @Test("MutationID has correct default content types")
    func mutationIDDefaults() {
        #expect(MutationID.stripTrackingParams.defaultContentTypes == [.url])
        #expect(MutationID.trimWhitespace.defaultContentTypes == [.plainText, .code])
    }

    @Test("All MutationIDs have display names")
    func allMutationsHaveNames() {
        for mutation in MutationID.allCases {
            #expect(!mutation.displayName.isEmpty)
        }
    }
}

// MARK: - Mock rules provider

@MainActor
final class MockMutationRules: MutationRulesProviding {
    var enabledRules: [String: Bool] = [:]
    var appOverrides: [String: Bool] = [:]

    func isEnabled(_ mutationID: MutationID, for contentType: ContentType) -> Bool {
        let key = "\(mutationID.rawValue):\(contentType.rawValue)"
        return enabledRules[key] ??
            (mutationID.defaultContentTypes.contains(contentType) && mutationID.enabledByDefault)
    }

    func isOverridden(_ mutationID: MutationID, for bundleID: String) -> Bool? {
        let key = "\(mutationID.rawValue):\(bundleID)"
        return appOverrides[key]
    }
}
