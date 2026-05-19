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
