import AppKit
@testable import Clipped
import Foundation
import Testing

/// Multi-service integration tests. Wires the real `ClipboardManager`,
/// `PasteboardMonitor`, `ClipboardHistory`, and mutation service together with
/// `MockPasteboard` + `MockHistoryStore` (so the real disk and clipboard stay
/// untouched) and drives flows end-to-end. Unlike the per-service unit tests,
/// these exercise the wiring between collaborators.
@MainActor
struct IntegrationTests {
    // swiftlint:disable large_tuple
    private func makeRig(persistHistory: Bool = true)
        -> (ClipboardManager, MockPasteboard, MockHistoryStore, MockSettingsManager)
    {
        // swiftlint:enable large_tuple
        let pasteboard = MockPasteboard()
        let manager = ClipboardManager(pasteboard: pasteboard)
        manager.stopMonitoring() // We drive `monitor.check()` deterministically.
        let store = MockHistoryStore()
        let settings = MockSettingsManager()
        settings.persistAcrossReboots = persistHistory
        manager.historyStore = store
        manager.settingsManager = settings
        return (manager, pasteboard, store, settings)
    }

    private func capture(_ text: String, on pasteboard: MockPasteboard) {
        pasteboard.stageExternalWrite(types: [.string], strings: [.string: text])
    }

    // MARK: - End-to-end ingest

    @Test("External pasteboard write flows monitor -> ingest -> history -> store")
    func captureToPersistence() async {
        let (manager, pasteboard, store, _) = makeRig()

        capture("Hello world", on: pasteboard)
        manager.monitor.check()
        await manager.flushPendingSaves()

        #expect(manager.items.count == 1)
        #expect(manager.items.first?.preview == "Hello world")

        let saved = await store.savedEntries
        #expect(saved.count == 1)
    }

    @Test("Multiple captures land in newest-first order")
    func multipleCapturesOrdering() async {
        let (manager, pasteboard, _, _) = makeRig()

        for text in ["one", "two", "three"] {
            capture(text, on: pasteboard)
            manager.monitor.check()
        }
        await manager.flushPendingSaves()

        #expect(manager.items.map(\.preview) == ["three", "two", "one"])
    }

    @Test("Identical content dedups instead of duplicating")
    func dedupOnRepeatedCapture() async {
        let (manager, pasteboard, _, _) = makeRig()

        capture("repeat", on: pasteboard)
        manager.monitor.check()
        capture("repeat", on: pasteboard) // bumps changeCount, same content
        manager.monitor.check()
        await manager.flushPendingSaves()

        #expect(manager.items.count == 1)
    }

    // MARK: - Settings <-> ingestion

    @Test("persistAcrossReboots=false captures in memory but never saves")
    func noPersistenceWhenDisabled() async {
        let (manager, pasteboard, store, _) = makeRig(persistHistory: false)

        capture("ephemeral", on: pasteboard)
        manager.monitor.check()
        await manager.flushPendingSaves()

        #expect(manager.items.count == 1)
        let saved = await store.savedEntries
        #expect(saved.isEmpty)
    }

    @Test("secureMode + timeout 0 drops password-manager content entirely")
    func secureModeSkipsConcealed() async {
        let (manager, pasteboard, _, settings) = makeRig()
        settings.secureMode = true
        settings.secureTimeout = 0

        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.stageExternalWrite(
            types: [concealed, .string],
            strings: [.string: "hunter2"]
        )
        manager.monitor.check()
        await manager.flushPendingSaves()

        #expect(manager.items.isEmpty)
    }

    @Test("secureMode + timeout > 0 ingests but does not persist")
    func secureModeWithTimeoutIngestsTransiently() async {
        let (manager, pasteboard, store, settings) = makeRig()
        settings.secureMode = true
        settings.secureTimeout = 30 // never elapses during the test

        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.stageExternalWrite(
            types: [concealed, .string],
            strings: [.string: "tempsecret"]
        )
        manager.monitor.check()
        await manager.flushPendingSaves()

        #expect(manager.items.count == 1)
        #expect(manager.items.first?.isSensitive == true)
        let saved = await store.savedEntries
        // Pending-removal items must never reach disk.
        #expect(saved.isEmpty)
    }

    // MARK: - Cap enforcement

    @Test("Size cap evicts the oldest non-pinned items on ingest")
    func maxHistorySizeCapEnforced() async {
        let (manager, pasteboard, _, settings) = makeRig()
        settings.maxHistorySize = 3

        for text in ["a", "b", "c", "d", "e"] {
            capture(text, on: pasteboard)
            manager.monitor.check()
        }
        await manager.flushPendingSaves()

        // Newest 3 survive, oldest evicted by `trimToMaxSize` inside ingest.
        #expect(manager.items.map(\.preview) == ["e", "d", "c"])
    }

    @Test("Pinned items survive the size cap")
    func pinnedSurviveCap() async {
        let (manager, pasteboard, _, settings) = makeRig()
        settings.maxHistorySize = 2

        capture("keep me", on: pasteboard)
        manager.monitor.check()
        // Pin the first one before the cap pushes it out.
        if let first = manager.items.first {
            manager.togglePin(first)
        }

        for text in ["b", "c", "d"] {
            capture(text, on: pasteboard)
            manager.monitor.check()
        }
        await manager.flushPendingSaves()

        #expect(manager.pinnedItems.map(\.preview) == ["keep me"])
        // Unpinned list capped at 2.
        #expect(manager.items.count == 2)
    }
}
