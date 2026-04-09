@testable import Clipped
import Foundation

@MainActor
final class MockHistoryStore: HistoryStoring {
    var savedItems: [ClipboardItem] = []
    var savedPinnedItems: [ClipboardItem] = []
    var saveCallCount = 0
    var clearCallCount = 0
    var loadResult: (items: [ClipboardItem], pinned: [ClipboardItem]) = ([], [])

    func save(items: [ClipboardItem], pinnedItems: [ClipboardItem]) {
        savedItems = items
        savedPinnedItems = pinnedItems
        saveCallCount += 1
    }

    func load() -> (items: [ClipboardItem], pinned: [ClipboardItem]) {
        loadResult
    }

    func clear() {
        clearCallCount += 1
    }
}

@MainActor
final class MockSettingsManager: SettingsManaging {
    var persistAcrossReboots = false
    var maxHistorySize = 10
    var secureMode = true
    var secureTimeout = 0
    var playSoundOnCopy = false
    var captureScreenshots = false
    var launchAtLogin = false
}

@MainActor
final class MockLinkMetadataFetcher: LinkMetadataFetching {
    var titlesByURL: [URL: String] = [:]
    var fetchCallCount = 0

    func fetchTitle(for url: URL) async -> String? {
        fetchCallCount += 1
        return titlesByURL[url]
    }
}
