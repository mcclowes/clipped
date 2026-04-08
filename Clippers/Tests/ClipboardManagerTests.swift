import Foundation
import Testing
@testable import Clippers

@MainActor
@Suite("ClipboardManager")
struct ClipboardManagerTests {
    @Test("Starts with empty history")
    func emptyHistory() {
        let manager = ClipboardManager()
        manager.stopMonitoring()
        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.isEmpty)
    }

    @Test("Filter by content type returns matching items only")
    func filterByType() {
        let manager = ClipboardManager()
        manager.stopMonitoring()

        let textItem = ClipboardItem(
            content: .text("hello"),
            contentType: .plainText
        )
        let urlItem = ClipboardItem(
            content: .url(URL(string: "https://example.com")!),
            contentType: .url
        )

        manager.items = [textItem, urlItem]
        manager.selectedContentType = .plainText

        #expect(manager.filteredItems.count == 1)
        #expect(manager.filteredItems.first?.contentType == .plainText)
    }

    @Test("Search filters items by preview text")
    func searchFilter() {
        let manager = ClipboardManager()
        manager.stopMonitoring()

        let item1 = ClipboardItem(content: .text("hello world"), contentType: .plainText)
        let item2 = ClipboardItem(content: .text("goodbye"), contentType: .plainText)

        manager.items = [item1, item2]
        manager.searchQuery = "hello"

        #expect(manager.filteredItems.count == 1)
        #expect(manager.filteredItems.first?.preview.contains("hello") == true)
    }

    @Test("Toggle pin moves item between lists")
    func togglePin() {
        let manager = ClipboardManager()
        manager.stopMonitoring()

        let item = ClipboardItem(content: .text("pin me"), contentType: .plainText)
        manager.items = [item]

        manager.togglePin(item)

        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.count == 1)
        #expect(item.isPinned == true)

        manager.togglePin(item)

        #expect(manager.items.count == 1)
        #expect(manager.pinnedItems.isEmpty)
        #expect(item.isPinned == false)
    }

    @Test("Remove item removes from correct list")
    func removeItem() {
        let manager = ClipboardManager()
        manager.stopMonitoring()

        let item = ClipboardItem(content: .text("remove me"), contentType: .plainText)
        manager.items = [item]

        manager.removeItem(item)

        #expect(manager.items.isEmpty)
    }

    @Test("Clear all preserves pinned items by default")
    func clearAllPreservesPinned() {
        let manager = ClipboardManager()
        manager.stopMonitoring()

        let pinned = ClipboardItem(content: .text("pinned"), contentType: .plainText)
        let unpinned = ClipboardItem(content: .text("unpinned"), contentType: .plainText)

        manager.pinnedItems = [pinned]
        manager.items = [unpinned]

        manager.clearAll()

        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.count == 1)
    }

    @Test("Content type detection")
    func contentTypes() {
        let textItem = ClipboardItem(content: .text("plain"), contentType: .plainText)
        #expect(textItem.contentType == .plainText)
        #expect(textItem.plainText == "plain")

        let urlItem = ClipboardItem(
            content: .url(URL(string: "https://example.com")!),
            contentType: .url
        )
        #expect(urlItem.contentType == .url)
        #expect(urlItem.plainText == "https://example.com")

        let imageItem = ClipboardItem(
            content: .image(Data(), CGSize(width: 100, height: 200)),
            contentType: .image
        )
        #expect(imageItem.preview.contains("100"))
        #expect(imageItem.preview.contains("200"))
    }
}
