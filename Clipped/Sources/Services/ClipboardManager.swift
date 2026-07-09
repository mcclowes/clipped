import AppKit
import Carbon
import Observation
import os
import SwiftUI

/// The primary defence is the `org.nspasteboard.ConcealedType` convention plus the entropy-based
/// `SecretDetector`; this bundle-ID fallback catches managers that don't set the concealed type.
/// Review periodically — it ages as new managers appear.
private let passwordManagerBundleIDs: Set<String> = [
    "com.agilebits.onepassword7",
    "com.agilebits.onepassword-osx",
    "com.1password.1password", // 1Password 8
    "com.lastpass.LastPass",
    "com.bitwarden.desktop",
    "org.keepassxc.keepassxc",
    "com.apple.Passwords", // Apple Passwords (macOS 15+)
    "com.dashlane.Dashlane",
    "in.sinew.Enpass-Desktop",
    "com.callpod.KeeperDesktop",
    "com.siber.roboform",
    "me.proton.pass.electron", // Proton Pass
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

    /// The app that was frontmost when the panel opened. Paste actions reactivate it before
    /// synthesising Cmd+V, so the keystroke lands in the user's app rather than in Clipped
    /// (which had to activate itself to take keyboard focus for the search field).
    private(set) var previousActiveApp: NSRunningApplication?

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

    /// Non-nil when persisted history couldn't be read at launch, so the UI can offer recovery.
    var historyLoadError: HistoryLoadError? {
        history.loadError
    }

    func retryHistoryLoad() async {
        await history.retryHistoryLoad()
    }

    func discardUnreadableHistory() async {
        await history.discardUnreadableHistory()
    }

    func trimToMaxSize() {
        history.trimToMaxSize()
    }

    func trimExpiredItems() {
        history.trimExpiredItems()
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
        let signpost = Signposts.clipboard.beginInterval("Ingest")
        defer { Signposts.clipboard.endInterval("Ingest", signpost) }

        let policy = passwordPolicy(hasConcealed: event.hasConcealedType, bundleID: event.bundleID)
        if policy.shouldSkip { return }

        let item = mutationService.apply(to: event.item, sourceAppBundleID: event.bundleID)

        // A mutation (e.g. trim-whitespace) can reduce content to nothing — don't store a blank row.
        if case let .text(str) = item.content, str.isEmpty { return }

        // Always flag password manager items as sensitive so they're never persisted to disk,
        // regardless of whether secure mode UI behavior is enabled.
        if policy.isFromPasswordManager {
            item.isSensitive = true
        }

        // Bound the secret scan — a multi-megabyte copy shouldn't run regexes over its full length.
        if let text = item.plainText, SecretDetector.containsSecret(String(text.prefix(100_000))) {
            item.containsSecret = true
        }

        history.insert(item)

        // Each ingest is a natural moment to evict already-expired items — no need
        // for a separate timer, since an idle clipboard has nothing to show anyway.
        history.trimExpiredItems()

        if policy.pendingRemoval {
            scheduleSecureAutoRemoval(itemID: item.id, timeout: policy.secureTimeout)
        }
        if case let .url(url) = item.content {
            scheduleLinkMetadataFetch(for: url, itemID: item.id)
        }
        if case .image = item.content {
            scheduleImageTextExtraction(for: item.id, content: item.content)
        }

        history.trimToMaxSize()

        if !policy.pendingRemoval {
            history.saveHistory()
        }
    }

    private func scheduleSecureAutoRemoval(itemID: UUID, timeout: Int) {
        Task { [weak self] in
            // Propagate cancellation: a cancelled sleep should NOT trigger removal (the opposite
            // of `try?`, which would fire the removal immediately on cancel).
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
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

    /// Caps concurrent Vision OCR jobs so a burst of image copies can't saturate the CPU.
    private static let ocrLimiter = TaskLimiter(limit: 2)

    private func scheduleImageTextExtraction(for itemID: UUID, content: ClipboardContent) {
        guard case let .image(data, _) = content else { return }
        Task { [weak self] in
            await Self.ocrLimiter.acquire()
            let text = await ImageTextExtractor.extractText(from: data)
            await Self.ocrLimiter.release()
            guard let self, let text else { return }
            if let found = history.items.first(where: { $0.id == itemID })
                ?? history.pinnedItems.first(where: { $0.id == itemID })
            {
                found.extractedText = text
                // OCR can surface secrets from screenshots of password managers, 2FA screens,
                // terminals, etc. Run the same detector the plain-text path uses so the item is
                // masked in the UI and kept out of typeahead search.
                if SecretDetector.containsSecret(text) {
                    found.containsSecret = true
                }
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
                Self.writeImageData(data, to: pasteboard)
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

    /// Writes synthesized `text` to the clipboard and records it as a fresh plain-text
    /// history entry. Unlike `copyToClipboard`, this content did not originate from
    /// another app — it's generated in-app (e.g. an on-device summary) so there is no
    /// existing item to move to the top. The monitor's own write suppression means we
    /// must insert into history explicitly.
    func copyText(_ text: String) {
        monitor.write { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        let item = ClipboardItem(content: .text(text), contentType: .plainText)
        history.insert(item)
        history.trimToMaxSize()
        history.saveHistory()

        if settingsManager?.playSoundOnCopy ?? true {
            NSSound(named: "Pop")?.play()
        }
    }

    private static func isPNGData(_ data: Data) -> Bool {
        // PNG magic: 89 50 4E 47 0D 0A 1A 0A
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= magic.count else { return false }
        return data.prefix(magic.count).elementsEqual(magic)
    }

    private static func isTIFFData(_ data: Data) -> Bool {
        // TIFF magic: "II*\0" (little-endian) or "MM\0*" (big-endian).
        let little: [UInt8] = [0x49, 0x49, 0x2A, 0x00]
        let big: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A]
        guard data.count >= 4 else { return false }
        let head = data.prefix(4)
        return head.elementsEqual(little) || head.elementsEqual(big)
    }

    /// Write image bytes to the pasteboard under a type apps can actually paste.
    /// PNG and TIFF advertise their native type directly; other formats (JPEG/HEIC
    /// produced by the image utilities) are handed over as a TIFF rendition so paste
    /// works everywhere — the compact original still lives in history.
    private static func writeImageData(_ data: Data, to pasteboard: PasteboardProtocol) {
        if isPNGData(data) {
            pasteboard.setData(data, forType: .png)
        } else if isTIFFData(data) {
            pasteboard.setData(data, forType: .tiff)
        } else if let tiff = NSImage(data: data)?.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    /// Snapshot the frontmost app just before the panel activates Clipped, so paste-back has a
    /// target to return focus to. Ignores Clipped itself.
    func captureFrontmostApp() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        previousActiveApp = frontmost
    }

    func pasteMatchingStyle(_ item: ClipboardItem) {
        pasteToActiveApp(item, asPlainText: true)
    }

    /// Copy `item`, return focus to the app that was active before the panel opened, then
    /// synthesise Cmd+V there. Without the reactivation the keystroke pastes into Clipped itself.
    func pasteToActiveApp(_ item: ClipboardItem, asPlainText: Bool = false) {
        let target = previousActiveApp
        copyToClipboard(item, asPlainText: asPlainText)
        Task {
            target?.activate()
            try? await Task.sleep(for: .milliseconds(120))
            // Only paste if the intended app actually regained focus (and secure input is off).
            guard !IsSecureEventInputEnabled() else { return }
            if let target,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier
            {
                return
            }
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

    // MARK: - Image utilities

    /// Lossily re-encode an image to shrink it, placing the result on the clipboard
    /// as a fresh history item. Async because the encode runs off the main actor.
    func compressImage(_ item: ClipboardItem) async {
        await applyImageTransform(item, mutation: "Compressed") { ImageProcessor.reencode($0, to: .jpeg, quality: 0.7) }
    }

    /// Convert an image to a different raster format (PNG/JPEG/HEIC).
    func convertImage(_ item: ClipboardItem, to format: RasterImageFormat) async {
        await applyImageTransform(item, mutation: "Converted to \(format.displayName)") {
            ImageProcessor.reencode($0, to: format)
        }
    }

    /// Downscale an image by `scale` (e.g. 0.5 = half size).
    func resizeImage(_ item: ClipboardItem, scale: Double) async {
        let percent = Int((scale * 100).rounded())
        await applyImageTransform(item, mutation: "Resized \(percent)%") { ImageProcessor.resize($0, scale: scale) }
    }

    /// Bytes for "Save as…", produced by `FileExporter`. Returns `nil` when the
    /// item can't be represented in `format`.
    func exportData(for item: ClipboardItem, format: ExportFormat) -> Data? {
        try? FileExporter.data(for: item, format: format)
    }

    private func applyImageTransform(
        _ item: ClipboardItem,
        mutation: String,
        _ transform: @escaping @Sendable (Data) -> Data?
    ) async {
        guard case let .image(data, _) = item.content else { return }

        // Decode + re-encode is CPU-bound; run it off the main actor so the UI stays live.
        let produced = await Task.detached(priority: .userInitiated) { () -> (Data, CGSize)? in
            guard let newData = transform(data), let size = ImageProcessor.pixelSize(of: newData) else {
                return nil
            }
            return (newData, size)
        }.value

        guard let (newData, size) = produced else {
            Self.logger.error("Image transform '\(mutation, privacy: .public)' failed")
            return
        }

        let result = ClipboardItem(
            content: .image(newData, size),
            contentType: .image,
            sourceAppName: item.sourceAppName,
            sourceAppBundleID: item.sourceAppBundleID
        )
        result.mutationsApplied = [mutation]

        monitor.write { pasteboard in
            pasteboard.clearContents()
            Self.writeImageData(newData, to: pasteboard)
        }

        history.insert(result)
        history.trimToMaxSize()
        history.saveHistory()

        if settingsManager?.playSoundOnCopy ?? true {
            NSSound(named: "Pop")?.play()
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

/// A tiny counting semaphore for structured tasks — bounds how many unstructured enrichment
/// jobs (e.g. Vision OCR) run at once so a paste-storm can't saturate the CPU.
actor TaskLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Resumed by `release()`, which hands its slot straight to us.
    }

    func release() {
        if waiters.isEmpty {
            running = max(0, running - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}
