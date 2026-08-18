@testable import Clipped
import Foundation
import Testing

@MainActor
struct TerminalTranscriptUnwrapTests {
    private let saggar = "com.mcclowes.saggar"

    private func unwrap(_ text: String, from bundleID: String? = "com.mcclowes.saggar", dev: Bool = true) -> String? {
        let item = ClipboardItem(
            content: .text(text),
            contentType: .plainText,
            sourceAppBundleID: bundleID,
            isDeveloperContent: dev
        )
        return UnwrapSoftLineBreaksMutation().mutate(item).plainText
    }

    @Test("Saggar is classified as a terminal")
    func saggarIsTerminal() {
        #expect(SourceAppCategory.category(for: saggar) == .terminal)
        #expect(SourceAppCategory.category(for: "com.mitchellh.ghostty") == .terminal)
    }

    @Test("Terminal-sourced text unwraps even though terminals mark items as developer content")
    func terminalIgnoresDeveloperFlag() {
        #expect(unwrap("a sentence that\nwrapped", from: "com.googlecode.iterm2") == "a sentence that wrapped")
    }

    @Test("Developer content from non-terminal apps is left alone")
    func nonTerminalDeveloperContentUntouched() {
        #expect(unwrap("a sentence that\nwrapped", from: "com.microsoft.VSCode") == "a sentence that\nwrapped")
    }

    @Test("Strips Claude Code message marker and joins its hanging-indent continuation lines")
    func claudeCodeMessage() {
        let text = "⏺ The unwrap mutation exists and is on by\n  default, but output is indented.\n\n"
            + "  Second paragraph that\n  wraps."
        #expect(
            unwrap(text)
                == "The unwrap mutation exists and is on by default, but output is indented.\n\n"
                + "Second paragraph that wraps."
        )
    }

    @Test("Unwraps wrapped list items nested inside a Claude Code message")
    func nestedListInMessage() {
        let text = "⏺ Plan:\n\n  - Item one wraps\n    here\n  - Item two\n  1. Numbered wraps\n     too"
        #expect(unwrap(text) == "Plan:\n\n- Item one wraps here\n- Item two\n1. Numbered wraps too")
    }

    @Test("Keeps tool output blocks verbatim while stripping their chrome")
    func toolOutputVerbatim() {
        let text = "⏺ Bash(ls -la)\n  ⎿  total 8\n     drwxr-xr-x  foo\n     drwxr-xr-x  bar"
        #expect(unwrap(text) == "Bash(ls -la)\ntotal 8\ndrwxr-xr-x  foo\ndrwxr-xr-x  bar")
    }

    @Test("Preserves indented code blocks inside a message and does not treat them as wraps")
    func codeBlockInMessage() {
        let text = "⏺ Run this and\n  read the output:\n\n    make build\n    make test"
        #expect(unwrap(text) == "Run this and read the output:\n\n  make build\n  make test")
    }

    @Test("Dedents a uniformly indented mid-message selection before unwrapping")
    func midMessageSelection() {
        #expect(unwrap("  first line wraps\n  here.") == "first line wraps here.")
    }

    @Test("Codex-style bullet messages keep their bullet and unwrap continuation lines")
    func codexBullet() {
        #expect(unwrap("• I checked the file and it\n  looks fine.") == "• I checked the file and it looks fine.")
    }

    @Test("Multiple Claude Code messages stay separate")
    func multipleMessages() {
        let text = "⏺ First message that\n  wraps.\n\n⏺ Second message that\n  wraps."
        #expect(unwrap(text) == "First message that wraps.\n\nSecond message that wraps.")
    }

    @Test("Terminal-sourced code output is left alone")
    func terminalCodeUntouched() {
        let text = "import Foundation\n\nfunc greet() {\n    print(\"hi\")\n}\n"
        #expect(unwrap(text) == text)
    }

    @Test("Full pipeline unwraps a mid-message selection even after trim removes the first indent")
    func pipelineMidMessageSelection() {
        let item = ClipboardItem(
            content: .text("  This selection started mid-message and\n  wraps onto a second line.\n"),
            contentType: .plainText,
            sourceAppBundleID: saggar,
            isDeveloperContent: true
        )
        let result = ClipboardMutationService().apply(to: item, sourceAppBundleID: saggar)
        #expect(result.plainText == "This selection started mid-message and wraps onto a second line.")
    }
}
