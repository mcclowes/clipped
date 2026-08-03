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

    static let defaultMaxHistorySize = 100
    private static let saveDebounceDelay: Duration = .milliseconds(250)

    var items: [ClipboardItem] = []
    var pinnedItems: [ClipboardItem] = []
    var searchQuery = ""
    var selectedFilter: ClipboardFilter?

    /// Settings source for persistence gating and max-history cap.
    var settingsManager: (any SettingsManaging)?
    /// Disk-backed store. Overridable for tests.
    var historyStore: any HistoryStoring = HistoryStore.shared

    /// Surfaced to the UI so it can offer a recovery choice when persisted history couldn't
    /// be read (wrong or locked Keychain key). `nil` means history loaded cleanly. While this
    /// is non-nil the store refuses to overwrite the unreadable file, so no data is lost.
    var loadError: HistoryLoadError?

    private var saveDebounceTask: Task<Void, Never>?

    /// True once `historyStore` has been read this session. Until it has been, `saveHistory()`
    /// refuses to write — history we have never read must not be overwritten by whatever
    /// happens to be in memory. Without this, enabling "persist across reboots" mid-session
    /// silently replaced the stored history with the current session's few items.
    private var hasLoadedFromStore = false
    private var loadTask: Task<Void, Never>?

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
        case let .category(category):
            result = result.filter { $0.detectedCategories.contains(category) }
        case let .sourceApp(sourceCategory):
            result = result.filter { $0.sourceAppCategory == sourceCategory }
        case nil:
            break
        }
        if !searchQuery.isEmpty {
            result = result.filter { item in
                if item.searchableText.localizedCaseInsensitiveContains(searchQuery) { return true }
                // Don't leak OCR'd secret text through typeahead — only match `extractedText`
                // on items that aren't masked as sensitive.
                if !item.isSensitive, !item.containsSecret,
                   let extracted = item.extractedText,
                   extracted.localizedCaseInsensitiveContains(searchQuery)
                {
                    return true
                }
                return false
            }
        }
        return result
    }

    // MARK: - Mutation

    /// Insert a new item at the top, replacing any existing unpinned item with identical content.
    func insert(_ item: ClipboardItem) {
        // Re-copying content that's already pinned shouldn't spawn a duplicate unpinned row.
        if pinnedItems.contains(where: { $0.content == item.content }) { return }

        // Carry the previous copy's enriched metadata (link preview, OCR text) onto the new item
        // so a re-copy doesn't discard work already done for identical content.
        if let existing = items.first(where: { $0.content == item.content }) {
            item.linkTitle = item.linkTitle ?? existing.linkTitle
            item.linkFavicon = item.linkFavicon ?? existing.linkFavicon
            item.extractedText = item.extractedText ?? existing.extractedText
        }
        items.removeAll { $0.content == item.content }
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
        remove(id: item.id)
    }

    /// Remove an item by identity from wherever it currently lives. Pinning moves items
    /// between the two arrays, so anything removing by id has to check both — the secure-mode
    /// timeout only cleared `items`, which let a password that had been pinned in the meantime
    /// survive its own expiry.
    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        pinnedItems.removeAll { $0.id == id }
        saveHistory()
    }

    func moveToTop(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let moved = items.remove(at: index)
        items.insert(moved, at: 0)
        // Persist the reorder — otherwise a relaunch resurrects the old order.
        saveHistory()
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
        eraseStoredHistory()
        return snapshot
    }

    /// Erase the durable copy, then write back whatever survived the clear (pinned items).
    ///
    /// Deliberately not routed through `saveHistory()`: that no-ops when `persistAcrossReboots`
    /// is off, which left a stored history sitting on disk after the user asked for it to go,
    /// ready to reappear the next time they enabled persistence. Clearing is destructive by
    /// intent, so it reaches the store regardless of the setting.
    private func eraseStoredHistory() {
        saveDebounceTask?.cancel()
        let store = historyStore
        let shouldPersist = settingsManager?.persistAcrossReboots == true
        let survivors = (items + pinnedItems)
            .filter { !$0.isSensitive }
            .map { StoredEntry(item: $0) }

        saveDebounceTask = Task { [survivors] in
            await store.clear()
            if shouldPersist, !survivors.isEmpty {
                await store.save(entries: survivors)
            }
        }
        // The store is now a known quantity, so later saves have nothing to clobber.
        hasLoadedFromStore = true
    }

    func restore(_ snapshot: ClearedSnapshot) {
        items = snapshot.items
        pinnedItems = snapshot.pinnedItems
        saveHistory()
    }

    /// Remove unpinned items older than the configured `historyRetention`.
    /// Pinned items, by design, are exempt — and `.never` retention disables expiry
    /// entirely so existing users see no behavior change until they opt in.
    func trimExpiredItems(now: Date = Date()) {
        guard let interval = settingsManager?.historyRetention.interval else { return }
        let cutoff = now.addingTimeInterval(-interval)
        items.removeAll { !$0.isPinned && $0.timestamp < cutoff }
    }

    /// Remove oldest unpinned items beyond the configured max history size.
    /// Only pinned items are exempt — they were explicitly kept by the user.
    func trimToMaxSize() {
        let limit = settingsManager?.maxHistorySize ?? Self.defaultMaxHistorySize
        while items.count(where: { !$0.isPinned }) > limit {
            if let lastTrimmable = items.lastIndex(where: { !$0.isPinned }) {
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
        loadError = await historyStore.lastLoadError()
        hasLoadedFromStore = true
        applyLoaded(entries)
    }

    /// Retry a load after a transient key failure (e.g. the user unlocked the Keychain).
    /// On success the recovery banner clears and the save block is lifted.
    func retryHistoryLoad() async {
        let entries = await historyStore.retryLoad()
        loadError = await historyStore.lastLoadError()
        guard loadError == nil else { return }
        hasLoadedFromStore = true
        applyLoaded(entries)
    }

    /// Discard the unreadable on-disk history and provision a fresh key. Only call this once
    /// the user has explicitly chosen to abandon the old (unrecoverable) data.
    func discardUnreadableHistory() async {
        await historyStore.startFresh()
        loadError = nil
        // The old data is gone by the user's explicit choice, so the store is now a known
        // (empty) quantity and saving is safe again.
        hasLoadedFromStore = true
    }

    private func applyLoaded(_ entries: [StoredEntry]) {
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
        items = merging(loaded, into: items)
        pinnedItems = merging(pinned, into: pinnedItems)
        // Drop anything already past its retention window from a previous session,
        // before the UI gets a chance to show stale items.
        trimExpiredItems()
    }

    /// Combine items read from disk with whatever is already in memory. Anything copied
    /// this session is newer than the stored copy, so it stays at the front and wins on an
    /// id or content collision; the rest is appended in stored order.
    ///
    /// This used to be `if items.isEmpty { items = loaded }`, which silently dropped the
    /// entire stored history whenever anything had been copied first — during the launch
    /// race, and (worse) on every "Retry" from the recovery alert.
    private func merging(_ loaded: [ClipboardItem], into existing: [ClipboardItem]) -> [ClipboardItem] {
        guard !existing.isEmpty else { return loaded }
        var seenIDs = Set(existing.map(\.id))
        var result = existing
        for item in loaded where !seenIDs.contains(item.id) {
            guard !existing.contains(where: { $0.content == item.content }) else { continue }
            seenIDs.insert(item.id)
            result.append(item)
        }
        return result
    }

    /// Snapshot current state and schedule a debounced async save. Safe to call rapidly.
    func saveHistory() {
        guard settingsManager?.persistAcrossReboots == true else { return }
        guard hasLoadedFromStore else {
            // Persistence was switched on after launch, so we have never read the stored
            // history and writing now would destroy it. Read it first; the load schedules
            // the save it displaced.
            loadThenSave()
            return
        }
        let entries = (items + pinnedItems)
            .filter { !$0.isSensitive }
            .map { StoredEntry(item: $0) }
        saveDebounceTask?.cancel()
        let store = historyStore

        // Span the whole save — debounce wait included — so the Instruments timeline
        // shows how rapid edits coalesce. A cancelled debounce still closes its
        // interval via the `defer`, so begin/end stay balanced.
        let signposter = Signposts.history
        let signpost = signposter.beginInterval("SaveHistory")
        saveDebounceTask = Task { [entries] in
            defer { signposter.endInterval("SaveHistory", signpost) }
            try? await Task.sleep(for: Self.saveDebounceDelay)
            guard !Task.isCancelled else { return }
            await store.save(entries: entries)
        }
    }

    /// Read the store, then run the save that `saveHistory()` deferred. Coalesced, so a
    /// burst of saves right after the setting flips only reads once.
    private func loadThenSave() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            await self?.loadPersistedHistory()
            self?.loadTask = nil
            self?.saveHistory()
        }
    }

    /// Await any in-flight load and debounced save. Intended for tests and app shutdown.
    func flushPendingSaves() async {
        // Order matters: a deferred load schedules the save, so it has to settle first.
        if let task = loadTask {
            _ = await task.value
        }
        if let task = saveDebounceTask {
            _ = await task.value
        }
    }
}
