import Carbon
@testable import Clipped
import Foundation

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

    private actor MockState {
        var savedEntries: [StoredEntry] = []
        var saveCallCount = 0
        var clearCallCount = 0
        var loadResult: [StoredEntry] = []

        func setLoadResult(_ entries: [StoredEntry]) {
            loadResult = entries
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
    var mutationRules: [String: Bool] = [:]
    var mutationAppOverrides: [String: Bool] = [:]

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
