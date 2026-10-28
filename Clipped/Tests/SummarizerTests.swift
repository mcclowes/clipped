@testable import Clipped
import Foundation
import Testing

@MainActor
struct SummarizerTests {
    private func textItem(
        _ string: String,
        sensitive: Bool = false,
        secret: Bool = false
    ) -> ClipboardItem {
        ClipboardItem(
            content: .text(string),
            contentType: .plainText,
            isSensitive: sensitive,
            containsSecret: secret
        )
    }

    @Test("Long plain text is eligible for summarization")
    func longTextEligible() {
        let item = textItem(String(repeating: "a", count: 500))
        #expect(Summarizer.canSummarize(item))
    }

    @Test("Short text is below the minimum length and not eligible")
    func shortTextIneligible() {
        #expect(!Summarizer.canSummarize(textItem("too short to summarize")))
    }

    @Test("Text exactly at the minimum length is eligible")
    func boundaryLength() {
        let item = textItem(String(repeating: "x", count: SummarizerConstants.minimumInputLength))
        #expect(Summarizer.canSummarize(item))
    }

    @Test("Sensitive items are never summarizable")
    func sensitiveExcluded() {
        let item = textItem(String(repeating: "a", count: 500), sensitive: true)
        #expect(!Summarizer.canSummarize(item))
    }

    @Test("Secret-bearing items are never summarizable")
    func secretExcluded() {
        let item = textItem(String(repeating: "a", count: 500), secret: true)
        #expect(!Summarizer.canSummarize(item))
    }

    @Test("Long rich text is eligible via its plain-text fallback")
    func richTextEligible() throws {
        let plain = String(repeating: "b", count: 500)
        let rtf = try #require(plain.data(using: .utf8))
        let item = ClipboardItem(content: .richText(rtf, plain), contentType: .richText)
        #expect(Summarizer.canSummarize(item))
    }

    @Test("Short rich text is not eligible")
    func shortRichTextIneligible() throws {
        let plain = "brief"
        let rtf = try #require(plain.data(using: .utf8))
        let item = ClipboardItem(content: .richText(rtf, plain), contentType: .richText)
        #expect(!Summarizer.canSummarize(item))
    }

    @Test("Long SVG markup is eligible through its text representation")
    func longSVGEligible() throws {
        let markup = "<svg><title>" + String(repeating: "a", count: 500) + "</title></svg>"
        let item = ClipboardItem(
            content: .svg(Data(markup.utf8), CGSize(width: 10, height: 10)),
            contentType: .image
        )
        try #require(item.plainText == markup)
        try #require(markup.count >= SummarizerConstants.minimumInputLength)
        try #require(item.isSensitive == false && item.containsSecret == false)
        #expect(Summarizer.canSummarize(item))
    }

    @Test("SVG uses the decoded character-count boundary", arguments: [-1, 0, 1])
    func svgLengthBoundary(offset: Int) throws {
        let length = SummarizerConstants.minimumInputLength + offset
        let markup = "<svg>" + String(repeating: "é", count: length - 11) + "</svg>"
        let item = ClipboardItem(
            content: .svg(Data(markup.utf8), CGSize(width: 10, height: 10)),
            contentType: .image
        )
        try #require(item.plainText?.count == length)
        #expect(Summarizer.canSummarize(item) == (offset >= 0))
    }

    @Test("SVG respects both privacy flags", arguments: [false, true], [false, true])
    func svgPrivacy(sensitive: Bool, secret: Bool) {
        let markup = "<svg><title>" + String(repeating: "a", count: 500) + "</title></svg>"
        let item = ClipboardItem(
            content: .svg(Data(markup.utf8), CGSize(width: 10, height: 10)),
            contentType: .image,
            isSensitive: sensitive,
            containsSecret: secret
        )
        #expect(Summarizer.canSummarize(item) == (!sensitive && !secret))
    }

    @Test("Undecodable SVG markup is not summarizable")
    func invalidSVGIneligible() throws {
        let item = ClipboardItem(
            content: .svg(Data(repeating: 0xFF, count: 500), CGSize(width: 10, height: 10)),
            contentType: .image
        )
        try #require(item.plainText == nil)
        #expect(Summarizer.canSummarize(item) == false)
    }

    @Test("Long URLs remain ineligible despite their text representation")
    func urlIneligible() throws {
        let url = try #require(URL(string: "https://example.invalid/" + String(repeating: "a", count: 500)))
        let item = ClipboardItem(content: .url(url), contentType: .url)
        try #require((item.plainText?.count ?? 0) >= SummarizerConstants.minimumInputLength)
        #expect(Summarizer.canSummarize(item) == false)
    }

    @Test("Non-text content is not summarizable")
    func imageIneligible() {
        let item = ClipboardItem(
            content: .image(Data(), CGSize(width: 10, height: 10)),
            contentType: .image
        )
        #expect(!Summarizer.canSummarize(item))
    }

    @Test("Error messages explain each failure mode")
    func errorDescriptions() {
        #expect(SummarizerError.unsupportedOS.errorDescription?.contains("macOS 26") == true)
        #expect(SummarizerError.modelUnavailable("Intel Mac").errorDescription?.contains("Intel Mac") == true)
        #expect(SummarizerError.emptyResponse.errorDescription?.isEmpty == false)
    }
}
