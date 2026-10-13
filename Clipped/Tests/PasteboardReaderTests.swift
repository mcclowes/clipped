import AppKit
@testable import Clipped
import Foundation
import Testing

@MainActor
struct PasteboardReaderTests {
    @Test("Reader preserves source metadata and developer tagging", arguments: [
        ("Terminal", "com.apple.Terminal", true),
        ("Xcode", "com.apple.dt.Xcode", true),
        ("Notes", "com.apple.Notes", false),
    ])
    func sourceMetadata(appName: String, bundleID: String, isDeveloperContent: Bool) throws {
        let mock = MockPasteboard()
        mock.stageExternalWrite(types: [.string], strings: [.string: "Ordinary prose"])

        let item = try #require(PasteboardReader(pasteboard: mock).read(appName: appName, bundleID: bundleID))

        #expect(item.plainText == "Ordinary prose")
        #expect(item.sourceAppName == appName)
        #expect(item.sourceAppBundleID == bundleID)
        #expect(item.isDeveloperContent == isDeveloperContent)
    }

    @Test("Only profiled source apps retain custom pasteboard payloads", arguments: [
        "com.apple.logic10", "com.apple.Notes",
    ])
    func customPayloads(bundleID: String) throws {
        let mock = MockPasteboard()
        let customType = NSPasteboard.PasteboardType("com.apple.logic.region")
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let textData = Data("Guitar".utf8)
        mock.stageExternalWrite(
            types: [.string, customType],
            strings: [.string: "Guitar"],
            data: [.string: textData, customType: payload]
        )

        let item = try #require(PasteboardReader(pasteboard: mock).read(appName: nil, bundleID: bundleID))

        #expect(item.plainText == "Guitar")
        if bundleID == "com.apple.logic10" {
            #expect(item.customPasteboardTypes == [
                NSPasteboard.PasteboardType.string.rawValue: textData, customType.rawValue: payload,
            ])
        } else {
            #expect(item.customPasteboardTypes == nil)
        }
    }

    @Test("Custom payload budget is inclusive and applies to all representations", arguments: [false, true])
    func customPayloadBudget(exceedsBudget: Bool) throws {
        let mock = MockPasteboard()
        let customType = NSPasteboard.PasteboardType("com.apple.logic.region")
        let byteLimit = 2 * 1024 * 1024
        let payload = Data(repeating: 0, count: byteLimit - 1)
        let textData = Data(repeating: 0, count: exceedsBudget ? 2 : 1)
        mock.stageExternalWrite(
            types: [.string, customType],
            strings: [.string: "Guitar"],
            data: [.string: textData, customType: payload]
        )

        let item = try #require(PasteboardReader(pasteboard: mock).read(
            appName: "Logic Pro",
            bundleID: "com.apple.logic10"
        ))

        #expect(item.plainText == "Guitar")
        if exceedsBudget {
            #expect(item.customPasteboardTypes == nil)
        } else {
            let snapshot = try #require(item.customPasteboardTypes)
            #expect(snapshot.count == 2)
            #expect(snapshot.values.reduce(0) { $0 + $1.count } == byteLimit)
        }
    }
}
