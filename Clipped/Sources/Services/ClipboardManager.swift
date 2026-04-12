import AppKit
import Carbon
import Observation
import os
import SwiftUI

private let passwordManagerBundleIDs: Set<String> = [
    "com.agilebits.onepassword7",
    "com.agilebits.onepassword-osx",
    "com.lastpass.LastPass",
    "com.bitwarden.desktop",
    "org.keepassxc.keepassxc",
]

/// Clipboard pipeline coordinator. Glues `PasteboardMonitor` (which produces raw items),
/// `ClipboardHistory` (which stores filtered/pinned state), and the mutation + link-metadata
/// services together. Also owns the pasteboard-writing actions (copy, paste, export).
///
/// This type used to be a 400-line god object; it is now narrow enough to be explained
/// in one sentence. View-facing API is kept stable via computed-property forwarding so
/// consumers of `@Environment(ClipboardManager.self)` do not churn.
@MainActor
@Observable
final class ClipboardManager {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "ClipboardManager")

    // MARK: - Collaborators

    let monitor: PasteboardMonitor
    let history: ClipboardHistory

    var mutationService: any ClipboardMutating = ClipboardMutationService()
    var linkMetadataFetcher: any LinkMetadataFetching = LinkMetadataFetcher.shared

    // MARK: - Transient UI state (not clipboard data)

    /// Set by the hotkey handler so the panel knows to suppress the quick-menu check.
    var openedViaHotkey = false
    /// Captured by `StatusBarController` when the user option-clicks the status bar icon,
    /// so the panel can read it synchronously instead of racing `NSEvent.modifierFlags`.
    var openedWithOption = false

    // MARK: - Forwarded history API (keeps existing view/test call sites working)

    typealias ClearedSnapshot = ClipboardHistory.ClearedSnapshot

    static let maxHistorySize = ClipboardHistory.defaultMaxHistorySize

    var items: [ClipboardItem] {
        get { history.items }
        set { history.items = newValue }
    }

    var pinnedItems: [ClipboardItem] {
        get { history.pinnedItems }
        set { history.pinnedItems = newValue }
    }

    var searchQuery: String {
        get { history.searchQuery }
        set { history.searchQuery = newValue }
    }

    var selectedFilter: ClipboardFilter? {
        get { history.selectedFilter }
        set { history.selectedFilter = newValue }
    }

    var filteredItems: [ClipboardItem] {
        history.filteredItems
    }

    var filteredPinnedItems: [ClipboardItem] {
        history.filteredPinnedItems
    }

    var recentSourceApps: [(bundleID: String, appName: String)] {
        history.recentSourceApps
    }

    var isMonitoring: Bool {
        monitor.isMonitoring
    }

    var settingsManager: (any SettingsManaging)? {
        get { history.settingsManager }
        set { history.settingsManager = newValue }
    }

    var historyStore: any HistoryStoring {
        get { history.historyStore }
        set { history.historyStore = newValue }
    }

    // MARK: - Init

    init(pasteboard: PasteboardProtocol = NSPasteboard.general) {
        monitor = PasteboardMonitor(pasteboard: pasteboard)
        history = ClipboardHistory()
        monitor.onNewItem = { [weak self] event in
            self?.ingest(event)
        }
    }

    // MARK: - Lifecycle

    /// Load persisted history and then start clipboard monitoring.
    /// Must be called from the AppDelegate after all dependencies have been wired.
    func bootstrap() async {
        await history.loadPersistedHistory()
        seedOnboardingExamplesIfNeeded()
        monitor.resetBaseline()
        monitor.startMonitoring()
    }

    /// On very first launch, inject one example of each content type so the clipboard
    /// panel isn't empty when the user opens it. Skipped if the history already contains
    /// anything — including pinned items restored from disk — so we never overwrite real
    /// clipboard data on an existing install.
    func seedOnboardingExamplesIfNeeded(
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        guard OnboardingSeeder.shouldSeed(defaults: defaults) else { return }
        defer { OnboardingSeeder.markSeeded(defaults: defaults) }

        guard history.items.isEmpty, history.pinnedItems.isEmpty else { return }

        history.items = OnboardingSeeder.makeSeedItems(now: now)
        history.saveHistory()
    }

    func startMonitoring() {
        monitor.startMonitoring()
    }

    func stopMonitoring() {
        monitor.stopMonitoring()
    }

    // MARK: - Forwarded history mutations

    func loadPersistedHistory() async {
        await history.loadPersistedHistory()
    }

    func saveHistory() {
        history.saveHistory()
    }

    func flushPendingSaves() async {
        await history.flushPendingSaves()
    }

    func trimToMaxSize() {
        history.trimToMaxSize()
    }

    func togglePin(_ item: ClipboardItem) {
        history.togglePin(item)
    }

    func removeItem(_ item: ClipboardItem) {
        history.removeItem(item)
    }

    @discardableResult
    func clearAll(includePinned: Bool = false) -> ClearedSnapshot {
        history.clearAll(includePinned: includePinned)
    }

    func restore(_ snapshot: ClearedSnapshot) {
        history.restore(snapshot)
    }

    // MARK: - Pipeline ingestion

    private struct PasswordManagerPolicy {
        let isFromPasswordManager: Bool
        let secureMode: Bool
        let secureTimeout: Int

        /// True when we should not ingest this item at all.
        var shouldSkip: Bool {
            isFromPasswordManager && secureMode && secureTimeout == 0
        }

        /// True when we ingest but schedule auto-removal (and do not persist).
        var pendingRemoval: Bool {
            isFromPasswordManager && secureMode && secureTimeout > 0
        }
    }

    private func passwordPolicy(hasConcealed: Bool, bundleID: String?) -> PasswordManagerPolicy {
        let isFromPasswordManager = hasConcealed
            || (bundleID.map { passwordManagerBundleIDs.contains($0) } ?? false)
        return PasswordManagerPolicy(
            isFromPasswordManager: isFromPasswordManager,
            secureMode: settingsManager?.secureMode ?? true,
            secureTimeout: settingsManager?.secureTimeout ?? 0
        )
    }

    private func ingest(_ event: PasteboardMonitor.NewItemEvent) {
        let policy = passwordPolicy(hasConcealed: event.hasConcealedType, bundleID: event.bundleID)
        if policy.shouldSkip { return }

        let item = mutationService.apply(to: event.item, sourceAppBundleID: event.bundleID)

        // Always flag password manager items as sensitive so they're never persisted to disk,
        // regardless of whether secure mode UI behavior is enabled.
        if policy.isFromPasswordManager {
            item.isSensitive = true
        }

        if let text = item.plainText, SecretDetector.containsSecret(text) {
            item.containsSecret = true
        }

        history.insert(item)

        if policy.pendingRemoval {
            scheduleSecureAutoRemoval(itemID: item.id, timeout: policy.secureTimeout)
        }
        if case let .url(url) = item.content {
            scheduleLinkMetadataFetch(for: url, itemID: item.id)
        }

        history.trimToMaxSize()

        if !policy.pendingRemoval {
            history.saveHistory()
        }
    }

    private func scheduleSecureAutoRemoval(itemID: UUID, timeout: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self else { return }
            history.items.removeAll { $0.id == itemID }
            history.saveHistory()
        }
    }

    private func scheduleLinkMetadataFetch(for url: URL, itemID: UUID) {
        // Respect the user's privacy preference — when previews are disabled we never
        // reach out to the remote origin.
        guard settingsManager?.fetchLinkPreviews ?? true else { return }
        let fetcher = linkMetadataFetcher
        Task { [weak self] in
            let metadata = await fetcher.fetchMetadata(for: url)
            guard let self else { return }
            // Look up by ID in case the item was replaced/restored after mutation.
            if let found = history.items.first(where: { $0.id == itemID })
                ?? history.pinnedItems.first(where: { $0.id == itemID })
            {
                found.linkTitle = metadata.title
                found.linkFavicon = metadata.favicon
                history.saveHistory()
            }
        }
    }

    // MARK: - Pasteboard-writing actions

    private static let vKeyCode: UInt16 = 0x09

    func copyToClipboard(_ item: ClipboardItem, asPlainText: Bool = false) {
        if !asPlainText, let customTypes = item.customPasteboardTypes {
            replayCustomPasteboardTypes(customTypes, item: item)
            return
        }
        monitor.write { pasteboard in
            pasteboard.clearContents()
            switch item.content {
            case let .text(string):
                pasteboard.setString(string, forType: .string)
            case let .richText(rtfData, plain):
                if asPlainText {
                    pasteboard.setString(plain, forType: .string)
                } else {
                    pasteboard.setData(rtfData, forType: .rtf)
                    pasteboard.setString(plain, forType: .string)
                }
            case let .url(url):
                pasteboard.setString(url.absoluteString, forType: .string)
            case let .image(data, _):
                // Sniff magic bytes so we advertise the real format.
                let pasteboardType: NSPasteboard.PasteboardType = Self.isPNGData(data) ? .png : .tiff
                pasteboard.setData(data, forType: pasteboardType)
            case let .svg(data, _):
                // Write three representations so paste works everywhere:
                // 1. The SVG markup as a string — code editors, text fields, terminals.
                // 2. The vector source under `public.svg-image` — design tools that
                //    understand SVG will preserve it losslessly.
                // 3. A rasterized TIFF fallback — Keynote, Slack, Mail, etc.
                if let markup = String(data: data, encoding: .utf8) {
                    pasteboard.setString(markup, forType: .string)
                }
                pasteboard.setData(data, forType: svgPasteboardType)
                if let tiff = NSImage(data: data)?.tiffRepresentation {
                    pasteboard.setData(tiff, forType: .tiff)
                }
            }
        }

        if settingsManager?.playSoundOnCopy ?? true {
            NSSound(named: "Pop")?.play()
        }

        history.moveToTop(item)
    }

    /// Replay a captured map of raw pasteboard type → data (Logic Pro regions, etc.)
    /// so paste into the source app works. Keeps `copyToClipboard` under the project's
    /// cyclomatic-complexity ceiling by extracting the early-return path.
    private func replayCustomPasteboardTypes(
        _ customTypes: [String: Data],
        item: ClipboardItem
    ) {
        monitor.write { pasteboard in
            pasteboard.clearContents()
            for (rawType, data) in customTypes {
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
        }
        if settingsManager?.playSoundOnCopy ?? true {
            NSSound(named: "Pop")?.play()
        }
        history.moveToTop(item)
    }

    private static func isPNGData(_ data: Data) -> Bool {
        // PNG magic: 89 50 4E 47 0D 0A 1A 0A
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= magic.count else { return false }
        return data.prefix(magic.count).elementsEqual(magic)
    }

    func pasteMatchingStyle(_ item: ClipboardItem) {
        // Copy as plain text, then simulate Cmd+V
        let targetApp = NSWorkspace.shared.frontmostApplication
        copyToClipboard(item, asPlainText: true)

        Task {
            try? await Task.sleep(for: .milliseconds(100))
            // Abort if focus changed during the delay to avoid pasting into the wrong app
            guard NSWorkspace.shared.frontmostApplication == targetApp else { return }
            simulatePaste()
        }
    }

    func simulatePaste() {
        // Don't inject keystrokes when secure input is active (e.g. password dialogs)
        if IsSecureEventInputEnabled() {
            return
        }

        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    func copyAsMarkdown(_ item: ClipboardItem) {
        guard case let .richText(rtfData, plain) = item.content,
              let markdown = MarkdownConverter.convert(rtfData: rtfData)
        else {
            copyToClipboard(item, asPlainText: true)
            return
        }

        monitor.write { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(markdown.isEmpty ? plain : markdown, forType: .string)
        }
    }

    func exportItems(_ items: [ClipboardItem]) {
        let merged = items.compactMap(\.plainText).joined(separator: "\n\n---\n\n")
        guard !merged.isEmpty else { return }

        monitor.write { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(merged, forType: .string)
        }
    }

    func restoreOriginal(_ item: ClipboardItem) {
        guard let original = item.originalContent else { return }
        item.content = original
        item.originalContent = nil
        item.mutationsApplied = []
        history.saveHistory()
    }
}
