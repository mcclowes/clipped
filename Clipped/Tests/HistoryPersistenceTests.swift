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

    @Test("Clearing history erases the stored copy even when persistence is off")
    func clearErasesStoredHistory() async {
        let rig = await makeRig(persist: false, stored: [storedEntry("from an earlier session")])
        rig.history.insert(textItem("in memory"))

        rig.history.clearAll()
        await rig.history.flushPendingSaves()

        let survivingOnDisk = await rig.store.load()
        #expect(survivingOnDisk.isEmpty, "cleared history must not come back on the next launch")
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
