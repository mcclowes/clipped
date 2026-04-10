import AppKit
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

    @Test("Mutation pipeline preserves developer tagging and link metadata")
    func pipelinePreservesAdditionalFields() throws {
        // Ensures the copyItem helper never drops side-channel fields. The previous bug was
        // that isDeveloperContent/linkTitle/linkFavicon/mutationsApplied were silently reset
        // whenever any mutation produced a new copy of the item.
        let service = ClipboardMutationService()
        let url = try #require(URL(string: "https://example.com/?utm_source=test"))
        let item = ClipboardItem(content: .url(url), contentType: .url)
        item.linkTitle = "Example"
        item.linkFavicon = Data([0xDE, 0xAD, 0xBE, 0xEF])
        item.isDeveloperContent = true

        let result = service.apply(to: item, sourceAppBundleID: nil)

        // StripTrackingParams runs and rewrites content. All prior fields must survive.
        #expect(result.linkTitle == "Example")
        #expect(result.linkFavicon == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(result.isDeveloperContent == true)
    }

    @Test("Mutation ordering: detectCodeSnippets runs last in default pipeline")
    func detectCodeSnippetsRunsLast() {
        // The pipeline depends on DetectCodeSnippet being last so it sees the final text.
        // If this invariant breaks (re-ordering), developer tagging behavior may regress.
        let defaults = ClipboardMutationService.defaultMutations()
        #expect(defaults.last?.id == .detectCodeSnippets)
    }

    // MARK: - CleanAmazonLinksMutation

    @Test("Cleans Amazon product URL to /dp/ASIN path")
    func cleanAmazonLink() throws {
        let mutation = CleanAmazonLinksMutation()
        let url = try #require(URL(
            string: "https://www.amazon.com/Some-Product-Name/dp/B08N5WRWNW/ref=sr_1_1?keywords=test&qid=123"
        ))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        let result = mutation.mutate(item)

        guard case let .url(cleanedURL) = result.content else {
            Issue.record("Expected URL content")
            return
        }
        #expect(cleanedURL.absoluteString == "https://www.amazon.com/dp/B08N5WRWNW")
    }

    @Test("Cleans Amazon UK links")
    func cleanAmazonUKLink() throws {
        let mutation = CleanAmazonLinksMutation()
        let url = try #require(URL(
            string: "https://www.amazon.co.uk/dp/B08N5WRWNW/ref=abc"
        ))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        let result = mutation.mutate(item)

        guard case let .url(cleanedURL) = result.content else {
            Issue.record("Expected URL content")
            return
        }
        #expect(cleanedURL.absoluteString == "https://www.amazon.co.uk/dp/B08N5WRWNW")
    }

    @Test("Ignores non-Amazon URLs")
    func ignoreNonAmazonURLs() throws {
        let mutation = CleanAmazonLinksMutation()
        let url = try #require(URL(string: "https://example.com/dp/B08N5WRWNW"))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        let result = mutation.mutate(item)

        #expect(result === item)
    }

    @Test("Ignores Amazon URLs without ASIN")
    func ignoreAmazonWithoutASIN() throws {
        let mutation = CleanAmazonLinksMutation()
        let url = try #require(URL(string: "https://www.amazon.com/deals"))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        let result = mutation.mutate(item)

        #expect(result === item)
    }

    // MARK: - SmartQuotesToStraightMutation

    @Test("Converts smart single quotes to straight")
    func convertSmartSingleQuotes() {
        let mutation = SmartQuotesToStraightMutation()
        let item = ClipboardItem(content: .text("it\u{2018}s a \u{2019}test\u{2019}"), contentType: .plainText)

        let result = mutation.mutate(item)

        guard case let .text(converted) = result.content else {
            Issue.record("Expected text content")
            return
        }
        #expect(converted == "it's a 'test'")
    }

    @Test("Converts smart double quotes to straight")
    func convertSmartDoubleQuotes() {
        let mutation = SmartQuotesToStraightMutation()
        let item = ClipboardItem(
            content: .text("\u{201C}hello\u{201D}"),
            contentType: .plainText
        )

        let result = mutation.mutate(item)

        guard case let .text(converted) = result.content else {
            Issue.record("Expected text content")
            return
        }
        #expect(converted == "\"hello\"")
    }

    @Test("Preserves text without smart quotes")
    func preserveTextWithoutSmartQuotes() {
        let mutation = SmartQuotesToStraightMutation()
        let item = ClipboardItem(content: .text("no smart quotes here"), contentType: .plainText)

        let result = mutation.mutate(item)

        #expect(result === item)
    }

    // MARK: - CollapseMultipleSpacesMutation

    @Test("Collapses multiple spaces to single")
    func collapseSpaces() {
        let mutation = CollapseMultipleSpacesMutation()
        let item = ClipboardItem(content: .text("hello   world    test"), contentType: .plainText)

        let result = mutation.mutate(item)

        guard case let .text(collapsed) = result.content else {
            Issue.record("Expected text content")
            return
        }
        #expect(collapsed == "hello world test")
    }

    @Test("Preserves text with single spaces")
    func preserveSingleSpaces() {
        let mutation = CollapseMultipleSpacesMutation()
        let item = ClipboardItem(content: .text("hello world"), contentType: .plainText)

        let result = mutation.mutate(item)

        #expect(result === item)
    }

    // MARK: - StripToPlainTextMutation

    @Test("Strips rich text to plain text")
    func stripRichText() {
        let mutation = StripToPlainTextMutation()
        let rtfData = Data()
        let item = ClipboardItem(
            content: .richText(rtfData, "plain fallback"),
            contentType: .richText
        )

        let result = mutation.mutate(item)

        guard case let .text(plain) = result.content else {
            Issue.record("Expected text content")
            return
        }
        #expect(plain == "plain fallback")
    }

    @Test("Ignores non-rich-text items")
    func stripIgnoresPlainText() {
        let mutation = StripToPlainTextMutation()
        let item = ClipboardItem(content: .text("hello"), contentType: .plainText)

        let result = mutation.mutate(item)

        #expect(result === item)
    }

    // MARK: - ConvertToMarkdownMutation

    @Test("Converts RTF to markdown")
    func convertRTFToMarkdown() throws {
        let mutation = ConvertToMarkdownMutation()
        // Create real RTF with bold text
        let attributed = NSMutableAttributedString(string: "hello bold world")
        attributed.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: 12),
            range: NSRange(location: 6, length: 4)
        )
        let rtfData = try #require(attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [:]
        ))
        let item = ClipboardItem(
            content: .richText(rtfData, "hello bold world"),
            contentType: .richText
        )

        let result = mutation.mutate(item)

        guard case let .text(markdown) = result.content else {
            Issue.record("Expected text content")
            return
        }
        #expect(markdown.contains("**bold**"))
    }

    @Test("Ignores non-rich-text for markdown conversion")
    func markdownIgnoresPlainText() {
        let mutation = ConvertToMarkdownMutation()
        let item = ClipboardItem(content: .text("hello"), contentType: .plainText)

        let result = mutation.mutate(item)

        #expect(result === item)
    }

    // MARK: - StripANSICodesMutation

    @Test("Strips ANSI color codes from text")
    func stripANSICodes() {
        let mutation = StripANSICodesMutation()
        let item = ClipboardItem(
            content: .text("\u{1B}[31mError:\u{1B}[0m something failed"),
            contentType: .plainText
        )

        let result = mutation.mutate(item)

        guard case let .text(stripped) = result.content else {
            Issue.record("Expected text content")
            return
        }
        #expect(stripped == "Error: something failed")
    }

    @Test("Strips multiple ANSI sequences")
    func stripMultipleANSI() {
        let mutation = StripANSICodesMutation()
        let item = ClipboardItem(
            content: .text("\u{1B}[1m\u{1B}[32mSuccess\u{1B}[0m: \u{1B}[34mdone\u{1B}[0m"),
            contentType: .plainText
        )

        let result = mutation.mutate(item)

        guard case let .text(stripped) = result.content else {
            Issue.record("Expected text content")
            return
        }
        #expect(stripped == "Success: done")
    }

    @Test("Preserves text without ANSI codes")
    func preserveTextWithoutANSI() {
        let mutation = StripANSICodesMutation()
        let item = ClipboardItem(content: .text("clean output"), contentType: .plainText)

        let result = mutation.mutate(item)

        #expect(result === item)
    }

    @Test("Ignores non-text items for ANSI stripping")
    func ansiIgnoresURLs() throws {
        let mutation = StripANSICodesMutation()
        let url = try #require(URL(string: "https://example.com"))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        let result = mutation.mutate(item)

        #expect(result === item)
    }

    // MARK: - MutationID

    @Test("MutationID has correct default content types")
    func mutationIDDefaults() {
        #expect(MutationID.stripTrackingParams.defaultContentTypes == [.url])
        #expect(MutationID.trimWhitespace.defaultContentTypes == [.plainText])
        #expect(MutationID.cleanAmazonLinks.defaultContentTypes == [.url])
        #expect(MutationID.smartQuotesToStraight.defaultContentTypes == [.plainText])
        #expect(MutationID.collapseMultipleSpaces.defaultContentTypes == [.plainText])
        #expect(MutationID.stripToPlainText.defaultContentTypes == [.richText])
        #expect(MutationID.convertToMarkdown.defaultContentTypes == [.richText])
        #expect(MutationID.stripANSICodes.defaultContentTypes == [.plainText])
    }

    @Test("New mutations are disabled by default")
    func newMutationsDisabledByDefault() {
        #expect(!MutationID.cleanAmazonLinks.enabledByDefault)
        #expect(!MutationID.smartQuotesToStraight.enabledByDefault)
        #expect(!MutationID.collapseMultipleSpaces.enabledByDefault)
        #expect(!MutationID.stripToPlainText.enabledByDefault)
        #expect(!MutationID.convertToMarkdown.enabledByDefault)
        #expect(!MutationID.stripANSICodes.enabledByDefault)
    }

    @Test("All MutationIDs have display names")
    func allMutationsHaveNames() {
        for mutation in MutationID.allCases {
            #expect(!mutation.displayName.isEmpty)
        }
    }

    @Test("Default mutations includes all mutation types")
    func defaultMutationsIncludesAll() {
        let mutations = ClipboardMutationService.defaultMutations()
        let ids = Set(mutations.map(\.id))
        #expect(ids.count == MutationID.allCases.count)
        for expected in MutationID.allCases {
            #expect(ids.contains(expected))
        }
    }

    // MARK: - DetectCodeSnippetMutation

    @Test("Detects import statements")
    func detectsImports() {
        let mutation = DetectCodeSnippetMutation()

        for code in [
            "import Foundation",
            "import React from 'react'",
            "from typing import Optional",
            "#include <stdio.h>",
            "const x = require('fs')",
        ] {
            let item = ClipboardItem(content: .text(code), contentType: .plainText)
            let result = mutation.mutate(item)
            #expect(result.isDeveloperContent, "Should flag as dev: \(code)")
        }
    }

    @Test("Detects function/variable declarations")
    func detectsDeclarations() {
        let mutation = DetectCodeSnippetMutation()

        for code in [
            "func greet(name: String) -> String {",
            "function handleClick(event) {",
            "def process_data(items):",
            "const API_URL = 'https://api.example.com'",
            "let count = items.filter { $0.isActive }",
            "var result: [String] = []",
        ] {
            let item = ClipboardItem(content: .text(code), contentType: .plainText)
            let result = mutation.mutate(item)
            #expect(result.isDeveloperContent, "Should flag as dev: \(code)")
        }
    }

    @Test("Detects multiline code with braces and semicolons")
    func detectsMultilineCode() {
        let mutation = DetectCodeSnippetMutation()

        let snippet = """
        if (user.isLoggedIn) {
            console.log("Welcome");
            return true;
        }
        """
        let item = ClipboardItem(content: .text(snippet), contentType: .plainText)
        let result = mutation.mutate(item)
        #expect(result.isDeveloperContent)
    }

    @Test("Detects shell commands")
    func detectsShellCommands() {
        let mutation = DetectCodeSnippetMutation()

        for code in [
            "npm install react",
            "pip install requests",
            "git commit -m 'fix bug'",
            "brew install wget",
            "cargo build --release",
        ] {
            let item = ClipboardItem(content: .text(code), contentType: .plainText)
            let result = mutation.mutate(item)
            #expect(result.isDeveloperContent, "Should flag as dev: \(code)")
        }
    }

    @Test("Detects arrow functions and common syntax")
    func detectsCodeSyntax() {
        let mutation = DetectCodeSnippetMutation()

        for code in [
            "const greet = (name) => {",
            "items.map(x => x.id)",
            "class UserService extends BaseService {",
        ] {
            let item = ClipboardItem(content: .text(code), contentType: .plainText)
            let result = mutation.mutate(item)
            #expect(result.isDeveloperContent, "Should flag as dev: \(code)")
        }
    }

    @Test("Does not flag plain prose as code")
    func rejectsPlainProse() {
        let mutation = DetectCodeSnippetMutation()

        for text in [
            "Hello, how are you?",
            "Meeting at 3pm tomorrow",
            "Buy milk and eggs",
            "The quick brown fox jumps over the lazy dog",
            "Let me know if you have any questions",
            "Please review the document and provide feedback",
        ] {
            let item = ClipboardItem(content: .text(text), contentType: .plainText)
            let result = mutation.mutate(item)
            #expect(result === item, "Should NOT detect: \(text)")
        }
    }

    @Test("Ignores non-text items")
    func codeDetectIgnoresURLs() throws {
        let mutation = DetectCodeSnippetMutation()
        let url = try #require(URL(string: "https://example.com"))
        let item = ClipboardItem(content: .url(url), contentType: .url)

        let result = mutation.mutate(item)

        #expect(result === item)
    }

    @Test("Skips items already flagged as developer content")
    func codeDetectSkipsExistingDevContent() {
        let mutation = DetectCodeSnippetMutation()
        let item = ClipboardItem(
            content: .text("import Foundation"),
            contentType: .plainText,
            isDeveloperContent: true
        )

        let result = mutation.mutate(item)

        #expect(result === item)
    }

    @Test("detectCodeSnippets is disabled by default")
    func codeDetectDisabledByDefault() {
        #expect(!MutationID.detectCodeSnippets.enabledByDefault)
    }

    @Test("detectCodeSnippets targets plainText")
    func codeDetectTargetsPlainText() {
        #expect(MutationID.detectCodeSnippets.defaultContentTypes == [.plainText])
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
