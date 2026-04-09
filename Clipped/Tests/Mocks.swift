import Carbon
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
    var hotkeyKeyCode: UInt32 = 8
    var hotkeyModifiers: UInt32 = .init(optionKey)
    var mutationRules: [String: Bool] = [:]
    var mutationAppOverrides: [String: Bool] = [:]
}

@MainActor
final class MockLinkMetadataFetcher: LinkMetadataFetching {
    var metadataByURL: [URL: LinkMetadata] = [:]
    var fetchCallCount = 0

    func fetchMetadata(for url: URL) async -> LinkMetadata {
        fetchCallCount += 1
        return metadataByURL[url] ?? LinkMetadata()
    }
}
