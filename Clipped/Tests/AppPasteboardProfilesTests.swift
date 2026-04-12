import AppKit
@testable import Clipped
import Foundation
import Testing

@MainActor
struct AppPasteboardProfilesTests {
    @Test("Logic Pro audio region preview extracts track name")
    func logicAudioRegionPreview() {
        let raw = "1 1 1 1      4 Guitar     7     149 1 1 105."
        let preview = AppPasteboardProfiles.logicPro.prettyPreview(raw)
        #expect(preview == "Logic Pro region — Guitar")
    }

    @Test("Logic Pro MIDI region preview extracts multi-word name")
    func logicMIDIRegionPreview() {
        let raw = "39 1 1 1      Deluxe Classic     6     2 0 0 0"
        let preview = AppPasteboardProfiles.logicPro.prettyPreview(raw)
        #expect(preview == "Logic Pro region — Deluxe Classic")
    }

    @Test("Logic Pro profile resolves from bundle ID")
    func profileLookup() {
        #expect(AppPasteboardProfiles.profile(for: "com.apple.logic10") != nil)
        #expect(AppPasteboardProfiles.profile(for: "com.apple.Safari") == nil)
        #expect(AppPasteboardProfiles.profile(for: nil) == nil)
    }

    @Test("Preview returns nil when no name tokens are present")
    func emptyNameReturnsNil() {
        #expect(AppPasteboardProfiles.logicPro.prettyPreview("1 2 3 4 5") == nil)
        #expect(AppPasteboardProfiles.logicPro.prettyPreview("") == nil)
    }

    @Test("ClipboardItem.preview uses app-specific formatter for Logic items")
    func itemPreviewUsesPrettyFormatter() {
        let item = ClipboardItem(
            content: .text("1 1 1 1      4 Guitar     7     149 1 1 105."),
            contentType: .plainText,
            sourceAppName: "Logic Pro",
            sourceAppBundleID: "com.apple.logic10"
        )
        #expect(item.preview == "Logic Pro region — Guitar")
    }

    @Test("ClipboardItem.preview falls back to default for non-profiled apps")
    func nonProfiledAppFallsBack() {
        let item = ClipboardItem(
            content: .text("hello world"),
            contentType: .plainText,
            sourceAppName: "Notes",
            sourceAppBundleID: "com.apple.Notes"
        )
        #expect(item.preview == "hello world")
    }

    @Test("ClipboardManager replays customPasteboardTypes on copy")
    func copyReplaysCustomTypes() {
        let mock = MockPasteboard()
        let manager = ClipboardManager(pasteboard: mock)

        let logicType = NSPasteboard.PasteboardType("com.apple.logic.region")
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let item = ClipboardItem(
            content: .text("1 1 1 1    Guitar    1 0 0 0"),
            contentType: .plainText,
            sourceAppName: "Logic Pro",
            sourceAppBundleID: "com.apple.logic10"
        )
        item.customPasteboardTypes = [
            logicType.rawValue: payload,
            NSPasteboard.PasteboardType.string.rawValue: Data("1 1 1 1    Guitar    1 0 0 0".utf8),
        ]

        manager.copyToClipboard(item)

        #expect(mock.data(forType: logicType) == payload)
        #expect(mock.types?.contains(logicType) == true)
    }

    @Test("ClipboardManager does not replay customPasteboardTypes when asPlainText is set")
    func copyAsPlainTextSkipsCustomTypes() {
        let mock = MockPasteboard()
        let manager = ClipboardManager(pasteboard: mock)

        let logicType = NSPasteboard.PasteboardType("com.apple.logic.region")
        let item = ClipboardItem(
            content: .text("Guitar preview"),
            contentType: .plainText,
            sourceAppName: "Logic Pro",
            sourceAppBundleID: "com.apple.logic10"
        )
        item.customPasteboardTypes = [logicType.rawValue: Data([0x01])]

        manager.copyToClipboard(item, asPlainText: true)

        #expect(mock.data(forType: logicType) == nil)
        #expect(mock.string(forType: .string) == "Guitar preview")
    }
}
