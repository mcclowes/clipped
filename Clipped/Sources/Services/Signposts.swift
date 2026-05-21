import os

/// Centralized `OSSignposter` handles for Clipped's performance instrumentation.
///
/// Signposts are near-zero cost when no tracing tool is attached, so they ship in
/// release builds without measurable overhead. Attach Instruments (the *os_signpost*
/// or *Points of Interest* instrument) and filter on subsystem `com.mcclowes.clipped`
/// to see the clipboard pipeline timeline.
///
/// Categories and interval/event names — keep `CLAUDE.md` in sync when changing these:
///
/// | Category      | Name                    | Kind     | Emitted from                       |
/// |---------------|-------------------------|----------|------------------------------------|
/// | Clipboard     | `Ingest`                | interval | `ClipboardManager.ingest(_:)`      |
/// | Clipboard     | `PasteboardChange`      | event    | `PasteboardMonitor.check()`        |
/// | History       | `SaveHistory`           | interval | `ClipboardHistory.saveHistory()`   |
/// | HistoryStore  | `Save`                  | interval | `HistoryStore.save(entries:)`      |
/// | HistoryStore  | `Load`                  | interval | `HistoryStore.load()`              |
/// | HistoryStore  | `CorruptedHistoryBackup`| event    | `HistoryStore.load()` recovery path|
/// | LinkMetadata  | `FetchMetadata`         | interval | `LinkMetadataFetcher.fetchMetadata`|
enum Signposts {
    /// Shared subsystem — matches the `os.Logger` subsystem used across the app.
    static let subsystem = "com.mcclowes.clipped"

    /// Clipboard ingestion pipeline and pasteboard polling.
    static let clipboard = OSSignposter(subsystem: subsystem, category: "Clipboard")

    /// In-memory history bookkeeping, including the debounced save window.
    static let history = OSSignposter(subsystem: subsystem, category: "History")

    /// Encrypted on-disk persistence.
    static let store = OSSignposter(subsystem: subsystem, category: "HistoryStore")

    /// Link-preview metadata fetches.
    static let linkMetadata = OSSignposter(subsystem: subsystem, category: "LinkMetadata")
}
