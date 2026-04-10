import AppKit
import Carbon
@testable import Clipped
import Foundation

/// In-memory pasteboard that records writes and can simulate external writes from other apps.
/// Matches `NSPasteboard`'s surface via `PasteboardProtocol` so both `PasteboardMonitor`
/// and `ClipboardManager` write paths can be unit-tested without touching the real clipboard.
@MainActor
final class MockPasteboard: PasteboardProtocol {
    private(set) var changeCount: Int = 0
    private var availableTypes: [NSPasteboard.PasteboardType] = []
    private var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
    private var stringByType: [NSPasteboard.PasteboardType: String] = [:]

    var types: [NSPasteboard.PasteboardType]? {
        availableTypes.isEmpty ? nil : availableTypes
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        dataByType[type]
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        stringByType[type]
    }

    @discardableResult
    func clearContents() -> Int {
        availableTypes.removeAll()
        dataByType.removeAll()
        stringByType.removeAll()
        changeCount += 1
        return changeCount
    }

    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        stringByType[type] = string
        if !availableTypes.contains(type) {
            availableTypes.append(type)
        }
        return true
    }

    @discardableResult
    func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool {
        guard let data else { return false }
        dataByType[type] = data
        if !availableTypes.contains(type) {
            availableTypes.append(type)
        }
        return true
    }

    /// Simulate an external app writing to the pasteboard: clears prior state, installs the
    /// given types/values, and bumps `changeCount` so the next `PasteboardMonitor.check()`
    /// treats it as fresh content.
    func stageExternalWrite(
        types: [NSPasteboard.PasteboardType],
        strings: [NSPasteboard.PasteboardType: String] = [:],
        data: [NSPasteboard.PasteboardType: Data] = [:]
    ) {
        availableTypes = types
        stringByType = strings
        dataByType = data
        changeCount += 1
    }
}

/// Sendable test double for HistoryStoring. State is protected by an internal actor
/// so the mock can be used from async tests and matches the production actor shape.
final class MockHistoryStore: HistoryStoring, @unchecked Sendable {
    /// Exposed for assertions; tests run serially on the main actor so unchecked is fine.
    private let state: MockState

    init() {
        state = MockState()
    }

    var savedEntries: [StoredEntry] {
        get async { await state.savedEntries }
    }

    var saveCallCount: Int {
        get async { await state.saveCallCount }
    }

    var clearCallCount: Int {
        get async { await state.clearCallCount }
    }

    func setLoadResult(_ entries: [StoredEntry]) async {
        await state.setLoadResult(entries)
    }

    func save(entries: [StoredEntry]) async {
        await state.save(entries: entries)
    }

    func load() async -> [StoredEntry] {
        await state.load()
    }

    func clear() async {
        await state.clear()
    }

    func lastLoadError() async -> HistoryLoadError? {
        await state.lastLoadError
    }

    func startFresh() async {
        await state.startFresh()
    }

    func setLastLoadError(_ error: HistoryLoadError?) async {
        await state.setLastLoadError(error)
    }

    private actor MockState {
        var savedEntries: [StoredEntry] = []
        var saveCallCount = 0
        var clearCallCount = 0
        var loadResult: [StoredEntry] = []
        var lastLoadError: HistoryLoadError?
        var startFreshCallCount = 0

        func setLoadResult(_ entries: [StoredEntry]) {
            loadResult = entries
        }

        func setLastLoadError(_ error: HistoryLoadError?) {
            lastLoadError = error
        }

        func save(entries: [StoredEntry]) {
            savedEntries = entries
            saveCallCount += 1
        }

        func load() -> [StoredEntry] {
            loadResult
        }

        func clear() {
            clearCallCount += 1
        }

        func startFresh() {
            startFreshCallCount += 1
            lastLoadError = nil
        }
    }
}

@MainActor
final class MockSettingsManager: SettingsManaging, MutationRulesProviding {
    var persistAcrossReboots = false
    var maxHistorySize = 10
    var secureMode = true
    var secureTimeout = 0
    var playSoundOnCopy = false
    var captureScreenshots = false
    var fetchLinkPreviews = true
    var launchAtLogin = false
    var hotkeyKeyCode: UInt32 = 8
    var hotkeyModifiers: UInt32 = .init(optionKey)
    var historyWindowHotkeyKeyCode: UInt32 = 8
    var historyWindowHotkeyModifiers: UInt32 = .init(optionKey | shiftKey)
    var mutationRules: [String: Bool] = [:]
    var mutationAppOverrides: [String: Bool] = [:]
    var disabledFilterIDs: Set<String> = []

    // MARK: - MutationRulesProviding

    func isEnabled(_ mutationID: MutationID, for contentType: ContentType) -> Bool {
        let key = "\(mutationID.rawValue):\(contentType.rawValue)"
        return mutationRules[key] ??
            (mutationID.defaultContentTypes.contains(contentType) && mutationID.enabledByDefault)
    }

    func isOverridden(_ mutationID: MutationID, for bundleID: String) -> Bool? {
        let key = "\(mutationID.rawValue):\(bundleID)"
        return mutationAppOverrides[key]
    }
}

final class MockLinkMetadataFetcher: LinkMetadataFetching, @unchecked Sendable {
    private let state: State

    init() {
        state = State()
    }

    var fetchCallCount: Int {
        get async { await state.fetchCallCount }
    }

    func setMetadata(_ metadata: LinkMetadata, for url: URL) async {
        await state.setMetadata(metadata, for: url)
    }

    func fetchMetadata(for url: URL) async -> LinkMetadata {
        await state.fetchMetadata(for: url)
    }

    private actor State {
        var metadataByURL: [URL: LinkMetadata] = [:]
        var fetchCallCount = 0

        func setMetadata(_ metadata: LinkMetadata, for url: URL) {
            metadataByURL[url] = metadata
        }

        func fetchMetadata(for url: URL) -> LinkMetadata {
            fetchCallCount += 1
            return metadataByURL[url] ?? LinkMetadata()
        }
    }
}
