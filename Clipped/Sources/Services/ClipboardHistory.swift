import AppKit
import Foundation
import Observation
import os

/// Holds the in-memory clipboard history (items + pinned items), search/filter state,
/// and persistence wiring. Does *not* know about pasteboard I/O, mutations, or link
/// metadata — those are the pipeline's concern.
@MainActor
@Observable
final class ClipboardHistory {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "ClipboardHistory")

    static let defaultMaxHistorySize = 50
    private static let saveDebounceDelay: Duration = .milliseconds(250)

    var items: [ClipboardItem] = []
    var pinnedItems: [ClipboardItem] = []
    var searchQuery = ""
    var selectedFilter: ClipboardFilter?

    /// Settings source for persistence gating and max-history cap.
    var settingsManager: (any SettingsManaging)?
    /// Disk-backed store. Overridable for tests.
    var historyStore: any HistoryStoring = HistoryStore.shared

    private var saveDebounceTask: Task<Void, Never>?

    init() {}

    // MARK: - Filtering

    var filteredPinnedItems: [ClipboardItem] {
        applyFilters(to: pinnedItems)
    }

    var filteredItems: [ClipboardItem] {
        applyFilters(to: items)
    }

    /// Unique (bundleID, appName) pairs from current history, for settings UI.
    var recentSourceApps: [(bundleID: String, appName: String)] {
        var seen = Set<String>()
        var result: [(bundleID: String, appName: String)] = []
        for item in items + pinnedItems {
            guard let bid = item.sourceAppBundleID, !seen.contains(bid) else { continue }
            seen.insert(bid)
            result.append((bid, item.sourceAppName ?? bid))
        }
        return result.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    private func applyFilters(to source: [ClipboardItem]) -> [ClipboardItem] {
        var result = source
        switch selectedFilter {
        case let .contentType(type):
            result = result.filter { $0.contentType == type }
        case .text:
            result = result.filter { $0.contentType == .plainText || $0.contentType == .richText }
        case .developer:
            result = result.filter(\.isDeveloperContent)
        case nil:
            break
        }
        if !searchQuery.isEmpty {
            result = result.filter { item in
                item.preview.localizedCaseInsensitiveContains(searchQuery)
            }
        }
        return result
    }

    // MARK: - Mutation

    /// Insert a new item at the top, removing any existing item with identical content.
    /// Pinned items are never displaced by dedup.
    func insert(_ item: ClipboardItem) {
        items.removeAll { $0.content == item.content && !$0.isPinned }
        items.insert(item, at: 0)
    }

    func togglePin(_ item: ClipboardItem) {
        item.isPinned.toggle()
        if item.isPinned {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items.remove(at: index)
            }
            pinnedItems.append(item)
        } else {
            pinnedItems.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
        }
        saveHistory()
    }

    func removeItem(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        pinnedItems.removeAll { $0.id == item.id }
        saveHistory()
    }

    func moveToTop(_ item: ClipboardItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let moved = items.remove(at: index)
            items.insert(moved, at: 0)
        }
    }

    // MARK: - Clear / restore

    /// Snapshot used to power Clear All → Undo in the panel.
    struct ClearedSnapshot {
        var items: [ClipboardItem]
        var pinnedItems: [ClipboardItem]
    }

    @discardableResult
    func clearAll(includePinned: Bool = false) -> ClearedSnapshot {
        let snapshot = ClearedSnapshot(items: items, pinnedItems: pinnedItems)
        items.removeAll()
        if includePinned {
            pinnedItems.removeAll()
        }
        saveHistory()
        return snapshot
    }

    func restore(_ snapshot: ClearedSnapshot) {
        items = snapshot.items
        pinnedItems = snapshot.pinnedItems
        saveHistory()
    }

    /// Remove oldest unpinned items beyond the configured max history size.
    /// Pinned and developer-content items are exempt from the cap.
    func trimToMaxSize() {
        let limit = settingsManager?.maxHistorySize ?? Self.defaultMaxHistorySize
        while items.count(where: { !$0.isPinned && !$0.isDeveloperContent }) > limit {
            if let lastTrimmable = items.lastIndex(where: { !$0.isPinned && !$0.isDeveloperContent }) {
                items.remove(at: lastTrimmable)
            }
        }
    }

    // MARK: - Persistence

    /// Load persisted history from disk. Safe to call multiple times — if the in-memory
    /// lists are already populated the load is a no-op, to avoid clobbering items copied
    /// between the start of the app and the async load completing.
    func loadPersistedHistory() async {
        guard settingsManager?.persistAcrossReboots == true else { return }
        let entries = await historyStore.load()
        var loaded: [ClipboardItem] = []
        var pinned: [ClipboardItem] = []
        for entry in entries {
            guard let item = entry.toClipboardItem() else { continue }
            if item.isPinned {
                pinned.append(item)
            } else {
                loaded.append(item)
            }
        }
        if items.isEmpty { items = loaded }
        if pinnedItems.isEmpty { pinnedItems = pinned }
    }

    /// Snapshot current state and schedule a debounced async save. Safe to call rapidly.
    func saveHistory() {
        guard settingsManager?.persistAcrossReboots == true else { return }
        let entries = (items + pinnedItems)
            .filter { !$0.isSensitive }
            .map { StoredEntry(item: $0) }
        saveDebounceTask?.cancel()
        let store = historyStore
        saveDebounceTask = Task { [entries] in
            try? await Task.sleep(for: Self.saveDebounceDelay)
            guard !Task.isCancelled else { return }
            await store.save(entries: entries)
        }
    }

    /// Await any in-flight debounced save. Intended for tests and app shutdown.
    func flushPendingSaves() async {
        if let task = saveDebounceTask {
            _ = await task.value
        }
    }
}
