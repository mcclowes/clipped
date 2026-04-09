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

    // MARK: - ClipboardMutationService pipeline

    @Test("Pipeline applies all enabled mutations")
    func pipelineAppliesAll() throws {
        let service = ClipboardMutationService()
        let url = try #require(URL(string: "https://example.com/?utm_source=test"))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        let result = service.apply(to: item)

        guard case let .url(cleanedURL) = result.content else {
            Issue.record("Expected URL content")
            return
        }
        #expect(cleanedURL.absoluteString == "https://example.com/")
    }

    @Test("Disabled mutations are skipped")
    func disabledMutationsSkipped() {
        let mutation = TrimWhitespaceMutation()
        mutation.isEnabled = false

        let service = ClipboardMutationService(mutations: [mutation])
        let item = ClipboardItem(content: .text("  hello  "), contentType: .plainText)

        let result = service.apply(to: item)

        #expect(result === item)
    }

    @Test("Mutation preserves item metadata")
    func preservesMetadata() throws {
        let mutation = StripTrackingParamsMutation()
        let url = try #require(URL(string: "https://example.com/?utm_source=test"))
        let item = ClipboardItem(
            content: .url(url),
            contentType: .url,
            sourceAppName: "Safari",
            sourceAppBundleID: "com.apple.Safari",
            isPinned: true,
            isSensitive: true
        )

        let result = mutation.mutate(item)

        #expect(result.id == item.id)
        #expect(result.sourceAppName == "Safari")
        #expect(result.sourceAppBundleID == "com.apple.Safari")
        #expect(result.isPinned == true)
        #expect(result.isSensitive == true)
        #expect(result.contentType == .url)
    }
}
