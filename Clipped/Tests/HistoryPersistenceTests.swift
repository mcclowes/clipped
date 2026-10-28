@testable import Clipped
import Foundation
import Testing

/// Behaviour of the persistence lifecycle: what reaches disk, when, and what is refused.
/// These are the paths where a mistake silently destroys the user's history, so they run
/// through `ClipboardHistory`'s public API against a mock store rather than poking at
/// internal flags.
@MainActor
struct HistoryPersistenceTests {
    private struct Rig {
        let history: ClipboardHistory
        let store: MockHistoryStore
        let settings: MockSettingsManager
    }

    private func makeRig(persist: Bool, stored: [StoredEntry] = []) async -> Rig {
        let store = MockHistoryStore()
        await store.setLoadResult(stored)
        let settings = MockSettingsManager()
        settings.persistAcrossReboots = persist
        let history = ClipboardHistory()
        history.settingsManager = settings
        history.historyStore = store
        return Rig(history: history, store: store, settings: settings)
    }

    private func storedEntry(_ text: String) -> StoredEntry {
        StoredEntry(item: ClipboardItem(content: .text(text), contentType: .plainText))
    }

    private func textItem(_ text: String) -> ClipboardItem {
        ClipboardItem(content: .text(text), contentType: .plainText)
    }

    @Test("The history store is constructed only when persistence needs it")
    func defersStoreConstruction() async {
        var constructions = 0
        let store = MockHistoryStore()
        let history = ClipboardHistory(historyStoreFactory: {
            constructions += 1
            return store
        })
        let settings = MockSettingsManager()
        settings.persistAcrossReboots = false
        history.settingsManager = settings

        await history.loadPersistedHistory()
        history.insert(textItem("in memory"))
        history.saveHistory()
        await history.flushPendingSaves()
        #expect(constructions == 0)

        settings.persistAcrossReboots = true
        await history.loadPersistedHistory()
        #expect(constructions == 1)
        #expect(history.historyStore as? MockHistoryStore === store)

        await history.loadPersistedHistory()
        history.saveHistory()
        await history.flushPendingSaves()
        #expect(constructions == 1)
        #expect(await store.savedEntries.compactMap(\.textContent) == ["in memory"])
    }

    @Test("Overriding the history store does not construct the default store")
    func storeOverrideSkipsFactory() async {
        var constructions = 0
        let unusedStore = MockHistoryStore()
        let history = ClipboardHistory(historyStoreFactory: {
            constructions += 1
            return unusedStore
        })
        let override = MockHistoryStore()
        await override.setLoadResult([storedEntry("from the override")])
        history.historyStore = override
        let settings = MockSettingsManager()
        settings.persistAcrossReboots = true
        history.settingsManager = settings

        await history.loadPersistedHistory()
        history.saveHistory()
        await history.flushPendingSaves()

        #expect(constructions == 0)
        #expect(history.historyStore as? MockHistoryStore === override)
        #expect(history.items.map(\.preview) == ["from the override"])
        #expect(await override.savedEntries.compactMap(\.textContent) == ["from the override"])
        #expect(await unusedStore.saveCallCount == 0)
    }

    @Test("Enabling persistence mid-session reads the store before it writes over it")
    func enablingPersistenceLoadsBeforeSaving() async {
        let rig = await makeRig(persist: false, stored: [storedEntry("persisted")])
        let history = rig.history

        // Launched with persistence off, so the store is never consulted.
        await history.loadPersistedHistory()
        history.insert(textItem("copied this session"))

        // User turns persistence on in Settings, then something triggers a save.
        rig.settings.persistAcrossReboots = true
        history.saveHistory()
        await history.flushPendingSaves()

        let texts = await rig.store.savedEntries.compactMap(\.textContent)
        #expect(texts.contains("persisted"), "history that was never read must not be overwritten")
        #expect(texts.contains("copied this session"))
    }

    @Test("Disabling persistence skips a queued save and re-enabling still saves normally")
    func disablingPersistenceSkipsQueuedSave() async {
        let rig = await makeRig(persist: true, stored: [storedEntry("persisted")])
        await rig.history.loadPersistedHistory()
        rig.history.insert(textItem("copied this session"))
        rig.history.saveHistory()
        rig.settings.persistAcrossReboots = false
        await rig.history.flushPendingSaves()

        #expect(await rig.store.saveCallCount == 0)
        #expect(await rig.store.savedEntries.isEmpty)
        #expect(await rig.store.load().compactMap(\.textContent) == ["persisted"])
        #expect(rig.history.items.map(\.preview) == ["copied this session", "persisted"])

        rig.settings.persistAcrossReboots = true
        rig.history.saveHistory()
        await rig.history.flushPendingSaves()
        #expect(await rig.store.saveCallCount == 1)
        #expect(await rig.store.savedEntries.compactMap(\.textContent) == ["copied this session", "persisted"])
    }

    @Test("Retrying an unreadable load keeps both the recovered and the newly copied items")
    func retryMergesRecoveredHistory() async {
        let rig = await makeRig(persist: true)
        let history = rig.history
        await rig.store.setLastLoadError(.decryptionFailed)

        await history.loadPersistedHistory()
        #expect(history.loadError == .decryptionFailed)

        // The recovery alert is up and the user carries on copying.
        history.insert(textItem("copied during outage"))

        // Keychain unlocked, so the original history is readable again.
        await rig.store.setLoadResult([storedEntry("recovered")])
        await rig.store.setLastLoadError(nil)
        await history.retryHistoryLoad()

        let previews = history.items.map(\.preview)
        #expect(previews.contains("recovered"), "retry must not discard what it just recovered")
        #expect(previews.contains("copied during outage"))
    }

    @Test("Dismissing a failed recovery keeps unreadable history protected and retryable")
    func dismissingLoadErrorKeepsHistoryProtected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClippedHistoryDismissTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = InMemoryKeyStore()
        let original = HistoryStore(keyStore: keys, baseDirectory: directory)
        await original.save(entries: [storedEntry("recoverable history")])
        let file = directory.appendingPathComponent("history.enc")
        let ciphertext = try Data(contentsOf: file)

        let unreadable = HistoryStore(keyStore: InMemoryKeyStore(), baseDirectory: directory)
        let settings = MockSettingsManager()
        settings.persistAcrossReboots = true
        let history = ClipboardHistory()
        history.settingsManager = settings
        history.historyStore = unreadable
        await history.loadPersistedHistory()
        #expect(history.loadError == .decryptionFailed)

        history.dismissHistoryLoadError()
        #expect(history.loadError == nil)
        history.insert(textItem("copied while locked"))
        await history.flushPendingSaves()
        #expect(try Data(contentsOf: file) == ciphertext)
        #expect(await unreadable.lastLoadError() == .decryptionFailed)

        await history.retryHistoryLoad()
        #expect(history.loadError == .decryptionFailed)
        history.dismissHistoryLoadError()
        #expect(history.loadError == nil)
        #expect(try Data(contentsOf: file) == ciphertext)

        history.historyStore = HistoryStore(keyStore: keys, baseDirectory: directory)
        await history.retryHistoryLoad()
        #expect(history.loadError == nil)
        #expect(Set(history.items.map(\.preview)) == ["recoverable history", "copied while locked"])
    }

    @Test("Clearing history erases the stored copy even when persistence is off")
    func clearErasesStoredHistory() async {
        let rig = await makeRig(persist: false, stored: [storedEntry("from an earlier session")])
        rig.history.insert(textItem("in memory"))

        rig.history.clearAll()
        await rig.history.flushPendingSaves()

        let survivingOnDisk = await rig.store.load()
        #expect(survivingOnDisk.isEmpty, "cleared history must not come back on the next launch")
    }

    @Test("Disabling persistence keeps a queued clear but skips writing its pinned survivors")
    func disablingPersistenceSkipsClearSurvivorSave() async {
        let rig = await makeRig(persist: true)
        await rig.history.loadPersistedHistory()
        let pinned = textItem("keep in memory")
        pinned.isPinned = true
        rig.history.pinnedItems = [pinned]
        rig.history.insert(textItem("drop me"))

        rig.history.clearAll()
        rig.settings.persistAcrossReboots = false
        await rig.history.flushPendingSaves()

        #expect(await rig.store.clearCallCount == 1)
        #expect(await rig.store.saveCallCount == 0)
        #expect(await rig.store.savedEntries.isEmpty)
        #expect(rig.history.items.isEmpty)
        #expect(rig.history.pinnedItems.map(\.id) == [pinned.id])
    }

    @Test("Clearing keeps pinned items on disk when persistence is on")
    func clearKeepsPinnedItemsPersisted() async {
        let rig = await makeRig(persist: true)
        let history = rig.history
        await history.loadPersistedHistory()

        let pinned = textItem("keep me")
        pinned.isPinned = true
        history.pinnedItems = [pinned]
        history.insert(textItem("drop me"))

        history.clearAll()
        await history.flushPendingSaves()

        let texts = await rig.store.savedEntries.compactMap(\.textContent)
        #expect(texts == ["keep me"])
    }
}
