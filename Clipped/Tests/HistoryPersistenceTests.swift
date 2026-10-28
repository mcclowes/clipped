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

private actor TerminationGate {
    private(set) var isOpen = false
    private var arrivals = 0
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func wait() async {
        arrivals += 1
        let ready = observers.filter { $0.0 <= arrivals }
        observers.removeAll { $0.0 <= arrivals }
        for (_, continuation) in ready {
            continuation.resume()
        }
        guard !isOpen else { return }
        await withCheckedContinuation { blocked.append($0) }
    }

    func waitForEntries(_ count: Int) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func open() {
        isOpen = true
        let waiting = blocked
        blocked.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

@MainActor
struct TerminationCoordinatorTests {
    @Test("A completed flush replies without waiting for the deadline", .timeLimit(.minutes(1)))
    func flushWins() async {
        let flush = TerminationGate()
        let deadline = TerminationGate()
        let coordinator = TerminationCoordinator { await deadline.wait() }
        let signal = AsyncStream<Void>.makeStream()
        var replies = 0
        coordinator.begin {
            await flush.wait()
        } reply: {
            replies += 1
            signal.continuation.yield()
        }
        await flush.waitForEntries(1)
        await deadline.waitForEntries(1)

        await flush.open()
        var events = signal.stream.makeAsyncIterator()
        await events.next()

        #expect(replies == 1)
        #expect(await deadline.isOpen == false)
        coordinator.begin { Issue.record("A repeated quit must not start another flush") } reply: {
            Issue.record("A repeated quit must not replace the reply")
        }
        await deadline.open()
    }

    @Test("The deadline replies while a flush ignores cancellation", .timeLimit(.minutes(1)))
    func deadlineWins() async {
        let flush = TerminationGate()
        let deadline = TerminationGate()
        let coordinator = TerminationCoordinator { await deadline.wait() }
        let signal = AsyncStream<Void>.makeStream()
        var replies = 0
        coordinator.begin {
            await flush.wait()
        } reply: {
            replies += 1
            signal.continuation.yield()
        }
        await flush.waitForEntries(1)
        await deadline.waitForEntries(1)

        await deadline.open()
        var events = signal.stream.makeAsyncIterator()
        await events.next()

        #expect(replies == 1)
        #expect(await flush.isOpen == false)
        await flush.open()
    }

    @Test("A successful flush cancels its sleeping deadline", .timeLimit(.minutes(1)))
    func cancelsDeadline() async {
        let flush = TerminationGate()
        let sleeping = AsyncStream<Void>.makeStream()
        let canceled = AsyncStream<Void>.makeStream()
        let coordinator = TerminationCoordinator {
            try await withTaskCancellationHandler {
                sleeping.continuation.yield()
                try await Task.sleep(for: .seconds(60))
            } onCancel: {
                canceled.continuation.yield()
            }
        }
        var replies = 0
        coordinator.begin { await flush.wait() } reply: { replies += 1 }
        var started = sleeping.stream.makeAsyncIterator()
        await started.next()

        await flush.open()
        var cancellations = canceled.stream.makeAsyncIterator()
        await cancellations.next()

        #expect(replies == 1)
    }
}

@MainActor
struct ClipboardTerminationTests {
    private struct DelayedMetadata: LinkMetadataFetching {
        let gate: TerminationGate

        func fetchMetadata(for _: URL) async -> LinkMetadata {
            await gate.wait()
            return LinkMetadata(title: "Late title", favicon: nil)
        }
    }

    @Test(
        "Shutdown rejects new captures and late enrichment before the final save",
        .bug(id: 122),
        .timeLimit(.minutes(1))
    )
    func stopsLateChanges() async throws {
        let pasteboard = MockPasteboard()
        let manager = ClipboardManager(pasteboard: pasteboard)
        let settings = MockSettingsManager()
        settings.persistAcrossReboots = true
        manager.settingsManager = settings
        let store = MockHistoryStore()
        manager.historyStore = store
        await manager.loadPersistedHistory()
        let gate = TerminationGate()
        manager.linkMetadataFetcher = DelayedMetadata(gate: gate)
        manager.extractImageText = { _ in
            await gate.wait()
            return "Late OCR"
        }
        let url = try #require(URL(string: "https://example.invalid/quit"))
        let link = ClipboardItem(content: .url(url), contentType: .url)
        let image = ClipboardItem(content: .image(Data([1]), CGSize(width: 1, height: 1)), contentType: .image)
        #expect(manager.ingest(.init(item: link, bundleID: nil, hasConcealedType: false)))
        #expect(manager.ingest(.init(item: image, bundleID: nil, hasConcealedType: false)))
        await gate.waitForEntries(2)
        manager.startMonitoring()

        manager.prepareForTermination()
        manager.prepareForTermination()
        manager.startMonitoring()
        let late = ClipboardItem(content: .text("Late capture"), contentType: .plainText)
        #expect(manager.ingest(.init(item: late, bundleID: nil, hasConcealedType: false)) == false)
        manager.copyText("Late summary")
        await manager.flushPendingSaves()
        let saveCount = await store.saveCallCount
        await gate.open()
        await manager.awaitPendingEnrichments()

        #expect(manager.isMonitoring == false)
        #expect(manager.monitor.onNewItem == nil)
        #expect(manager.items.map(\.id) == [image.id, link.id])
        #expect(pasteboard.changeCount == 0)
        #expect(link.linkTitle == nil && image.extractedText == nil)
        #expect(image.isAwaitingImageText)
        #expect(await store.saveCallCount == saveCount)
        #expect(await store.savedEntries.map(\.id) == [link.id])
    }

    @Test(
        "Shutdown cancels secure-removal jobs without deleting the final snapshot",
        .bug(id: 122),
        .timeLimit(.minutes(1))
    )
    func cancelsSecureRemoval() async {
        let manager = ClipboardManager(pasteboard: MockPasteboard())
        manager.historyStore = MockHistoryStore()
        manager.settingsManager = MockSettingsManager()
        manager.secureRemovalDelay = { _ in .seconds(1) }
        let item = ClipboardItem(content: .text("Synthetic private capture"), contentType: .plainText)
        #expect(manager.ingest(.init(item: item, bundleID: nil, hasConcealedType: true)))

        manager.prepareForTermination()
        await manager.awaitPendingSecureRemovals()

        #expect(manager.items.map(\.id) == [item.id])
    }
}
