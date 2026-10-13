import AppKit
@testable import Clipped
import Foundation
import Testing

@MainActor
struct StoredEntryTests {
    @Test("Externalizing and hydrating image bytes preserves all persisted metadata")
    func imagePayloadReplacement() throws {
        let payload = Data([1, 2, 3])
        let item = ClipboardItem(
            content: .image(payload, CGSize(width: 20, height: 30)),
            contentType: .image,
            sourceAppName: "Example",
            sourceAppBundleID: "com.example.app",
            timestamp: Date(timeIntervalSince1970: 123),
            isPinned: true,
            containsSecret: true,
            isDeveloperContent: true,
            detectedCategories: [.number]
        )
        item.linkTitle = "Title"
        item.linkFavicon = Data([4])
        item.mutationsApplied = ["Resize"]
        item.htmlData = Data("<p>Example</p>".utf8)
        item.customPasteboardTypes = ["com.example.payload": Data([5])]
        item.extractedText = "Recognized text"
        item.originalContent = .image(Data([6]), CGSize(width: 40, height: 60))

        let entry = StoredEntry(item: item)
        let stripped = entry.strippingImageData()
        var expected = try json(entry)
        expected.removeValue(forKey: "imageData")
        #expect(try json(stripped) == expected)
        #expect(stripped.imageData == nil)

        let hydrated = stripped.withImageData(payload)
        #expect(try json(hydrated) == json(entry))
        #expect(hydrated.imageData == payload)
        #expect(entry.imageData == payload)
    }

    @Test("Legacy Code entries decode as text with missing optional metadata")
    func legacyCodeEntry() throws {
        let fixture = Data("""
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "contentType": "Code",
            "textContent": "let answer = 42",
            "timestamp": 123,
            "isPinned": false
        }
        """.utf8)
        let entry = try JSONDecoder().decode(StoredEntry.self, from: fixture)
        let item = try #require(entry.toClipboardItem())
        #expect(item.contentType == .plainText)
        #expect(item.plainText == "let answer = 42")
        #expect(item.containsSecret == false)
        #expect(item.isDeveloperContent == false)
        #expect(item.detectedCategories.isEmpty)
        #expect(item.mutationsApplied.isEmpty)
    }

    private func json(_ entry: StoredEntry) throws -> [String: NSObject] {
        let data = try JSONEncoder().encode(entry)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: NSObject])
    }
}
