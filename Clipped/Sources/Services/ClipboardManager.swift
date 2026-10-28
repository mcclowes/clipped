import AppKit
import Carbon
import LocalAuthentication
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

/// Coordinates clipboard ingestion, protected actions, and history updates.
/// Pasteboard encoding belongs to `ClipboardPasteboardWriter`.
@MainActor
@Observable
final class ClipboardManager {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "ClipboardManager")

    // MARK: - Collaborators

    let monitor: PasteboardMonitor
    let history: ClipboardHistory

    var mutationService: any ClipboardMutating = ClipboardMutationService()
    var linkMetadataFetcher: any LinkMetadataFetching = LinkMetadataFetcher.shared
    var extractImageText: @Sendable (Data) async -> String? = { data in
        await ImageTextExtractor.extractText(from: data)
    }

    @ObservationIgnored
    var pasteBackEnvironment: any PasteBackEnvironment = WorkspacePasteBackEnvironment()

    @ObservationIgnored
    var dismissPanelForPaste: (() -> Void)?

    @ObservationIgnored
    var previewImage: (ClipboardItem) throws -> Void = { item in
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSSound.beep()
            return
        }
        let image = try FileExporter.temporaryPreviewURL(for: item)
        NSWorkspace.shared.open(
            [image],
            withApplicationAt: preview,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @ObservationIgnored
    var renderExportData: (ClipboardItem, ExportFormat) -> Data? = { item, format in
        try? FileExporter.data(for: item, format: format)
    }

    /// Injectable authentication seam so secret-access behavior can be tested without showing
    /// a system prompt. The default uses the Mac's configured owner-authentication policy.
    typealias SecretAccessAuthenticator = (
        _ reason: String,
        _ completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Void

    @ObservationIgnored
    var authenticateSecretAccess: SecretAccessAuthenticator = { reason, completion in
        ClipboardManager.authenticateOwner(reason: reason, completion: completion)
    }

    static func authenticateOwner(
        reason: String,
        context: LAContext = LAContext(),
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            completion(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            Task { @MainActor in completion(success) }
        }
    }

    // MARK: - Transient UI state (not clipboard data)

    /// Set by the hotkey handler so the panel knows to suppress the quick-menu check.
    var openedViaHotkey = false
    /// Captured by `StatusBarController` when the user option-clicks the status bar icon,
    /// so the panel can read it synchronously instead of racing `NSEvent.modifierFlags`.
    var openedWithOption = false

    /// The app that was frontmost when the panel or history opened. Paste actions reactivate it before
    /// synthesising Cmd+V, so the keystroke lands in the user's app rather than in Clipped
    /// (which had to activate itself to take keyboard focus for the search field).
    private(set) var previousActiveApp: (any PasteBackApplication)?

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

    @discardableResult
    func ingest(_ event: PasteboardMonitor.NewItemEvent) -> Bool {
        let signpost = Signposts.clipboard.beginInterval("Ingest")
        defer { Signposts.clipboard.endInterval("Ingest", signpost) }

        if case let .image(data, _) = event.item.content, data.count > PasteboardMonitor.maxImageBytes {
            return false
        }

        let policy = passwordPolicy(hasConcealed: event.hasConcealedType, bundleID: event.bundleID)
        if policy.shouldSkip {
            return false
        }

        let incoming = mutationService.apply(to: event.item, sourceAppBundleID: event.bundleID)

        // A mutation (e.g. trim-whitespace) can reduce content to nothing — don't store a blank row.
        if case let .text(str) = incoming.content, str.isEmpty {
            return false
        }

        // Always flag password manager items as sensitive so they're never persisted to disk,
        // regardless of whether secure mode UI behavior is enabled.
        if policy.isFromPasswordManager {
            incoming.isSensitive = true
        }

        if case .image = incoming.content {
            incoming.isAwaitingImageText = true
        }

        guard let item = history.insert(incoming) else { return false }
        let secretPendingRemoval = applySecretRetentionPolicy(to: item)

        // Each ingest is a natural moment to evict already-expired items — no need
        // for a separate timer, since an idle clipboard has nothing to show anyway.
        history.trimExpiredItems()

        if policy.pendingRemoval || secretPendingRemoval {
            scheduleSecureAutoRemoval(itemID: item.id, timeout: policy.secureTimeout)
        }
        if case let .url(url) = item.content {
            scheduleLinkMetadataFetch(for: url, itemID: item.id)
        }
        if case .image = item.content {
            scheduleImageTextExtraction(for: item.id, content: item.content)
        }

        history.trimToMaxSize()

        if !policy.pendingRemoval, !secretPendingRemoval {
            history.saveHistory()
        }
        return true
    }

    private func applySecretRetentionPolicy(to item: ClipboardItem) -> Bool {
        guard item.containsSecret, settingsManager?.secretHandling == .treatLikePasswords else { return false }
        item.isSensitive = true
        return true
    }

    /// How long a secure-mode item survives before eviction. Injected so tests can drive the
    /// timeout without waiting real seconds.
    var secureRemovalDelay: @Sendable (Int) -> Duration = { .seconds($0) }

    /// Retained per item so removals can be awaited in tests and so a manual delete can
    /// cancel the timer rather than leaving it to fire against nothing.
    private var secureRemovalTasks: [UUID: Task<Void, Never>] = [:]

    private func scheduleSecureAutoRemoval(itemID: UUID, timeout: Int) {
        let delay = secureRemovalDelay(timeout)
        secureRemovalTasks[itemID]?.cancel()
        secureRemovalTasks[itemID] = Task { [weak self] in
            // Propagate cancellation: a cancelled sleep should NOT trigger removal (the opposite
            // of `try?`, which would fire the removal immediately on cancel).
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            // Remove by id from both collections — pinning moves the item out of `history.items`.
            history.remove(id: itemID)
            secureRemovalTasks[itemID] = nil
        }
    }

    /// Await every scheduled secure removal. Test seam.
    func awaitPendingSecureRemovals() async {
        for task in secureRemovalTasks.values {
            _ = await task.value
        }
    }

    private var enrichmentTasks: [UUID: Task<Void, Never>] = [:]

    func awaitPendingEnrichments() async {
        for task in enrichmentTasks.values {
            await task.value
        }
    }

    func awaitPendingEnrichment(for itemID: UUID) async {
        await enrichmentTasks[itemID]?.value
    }

    private func scheduleLinkMetadataFetch(for url: URL, itemID: UUID) {
        // Respect the user's privacy preference — when previews are disabled we never
        // reach out to the remote origin.
        guard settingsManager?.fetchLinkPreviews ?? true, enrichmentTasks[itemID] == nil else { return }
        let fetcher = linkMetadataFetcher
        enrichmentTasks[itemID] = Task { [weak self] in
            let metadata = await fetcher.fetchMetadata(for: url)
            guard let self else { return }
            defer { enrichmentTasks[itemID] = nil }
            // Look up by ID in case the item was replaced/restored after mutation.
            if let found = history.items.first(where: { $0.id == itemID })
                ?? history.pinnedItems.first(where: { $0.id == itemID })
            {
                found.linkTitle = metadata.title ?? found.linkTitle
                found.linkFavicon = metadata.favicon ?? found.linkFavicon
                history.saveHistory()
            }
        }
    }

    /// Caps concurrent Vision OCR jobs so a burst of image copies can't saturate the CPU.
    private static let ocrLimiter = TaskLimiter(limit: 2)

    private func scheduleImageTextExtraction(for itemID: UUID, content: ClipboardContent) {
        guard case let .image(data, _) = content, enrichmentTasks[itemID] == nil else { return }
        let extract = extractImageText
        enrichmentTasks[itemID] = Task { [weak self] in
            defer { self?.enrichmentTasks[itemID] = nil }
            let text: String?
            do {
                text = try await Self.ocrLimiter.withPermit { await extract(data) }
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            if let found = history.items.first(where: { $0.id == itemID })
                ?? history.pinnedItems.first(where: { $0.id == itemID })
            {
                if let text {
                    found.extractedText = text
                }
                // OCR can surface secrets from screenshots of password managers, 2FA screens,
                // terminals, etc. Run the same detector the plain-text path uses so the item is
                // masked in the UI and kept out of typeahead search.
                if let text = found.extractedText, SecretDetector.containsSecret(text) {
                    found.containsSecret = true
                    if applySecretRetentionPolicy(to: found) {
                        scheduleSecureAutoRemoval(
                            itemID: found.id,
                            timeout: settingsManager?.secureTimeout ?? SettingsManager.defaultSecureTimeout
                        )
                    }
                }
                found.isAwaitingImageText = false
                history.saveHistory()
            }
        }
    }

    // MARK: - Pasteboard-writing actions

    func copyToClipboard(
        _ item: ClipboardItem,
        asPlainText: Bool = false,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        performExplicitSecretAction(for: item, reason: "Copy hidden clipboard content") { [weak self] in
            self?.writeToClipboard(item, asPlainText: asPlainText)
            completion?()
        }
    }

    private func writeToClipboard(_ item: ClipboardItem, asPlainText: Bool = false) {
        monitor.write { pasteboard in
            ClipboardPasteboardWriter.write(item, asPlainText: asPlainText, to: pasteboard)
        }
        finishCopying(item)
    }

    func copyToClipboard(
        _ item: ClipboardItem,
        as representation: ClipboardRepresentation,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        performExplicitSecretAction(for: item, reason: "Copy hidden clipboard content") { [weak self] in
            self?.writeToClipboard(item, as: representation)
            completion?()
        }
    }

    private func writeToClipboard(_ item: ClipboardItem, as representation: ClipboardRepresentation) {
        monitor.write { pasteboard in
            ClipboardPasteboardWriter.write(item, as: representation, to: pasteboard)
        }
        finishCopying(item)
    }

    private func finishCopying(_ item: ClipboardItem) {
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
        let item = ClipboardItem(content: .text(text), contentType: .plainText)
        performExplicitSecretAction(for: item, reason: "Copy hidden clipboard content") { [weak self] in
            self?.writeGeneratedTextItem(item)
        }
    }

    private func writeGeneratedTextItem(_ item: ClipboardItem) {
        guard case let .text(text) = item.content else { return }
        monitor.write { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        if let retained = history.insert(item) {
            let pendingRemoval = applySecretRetentionPolicy(to: retained) || retained.isSensitive
            history.trimToMaxSize()
            if pendingRemoval {
                scheduleSecureAutoRemoval(
                    itemID: retained.id,
                    timeout: settingsManager?.secureTimeout ?? SettingsManager.defaultSecureTimeout
                )
            } else {
                history.saveHistory()
            }
        }

        if settingsManager?.playSoundOnCopy ?? true {
            NSSound(named: "Pop")?.play()
        }
    }

    func copyExtractedText(from source: ClipboardItem) {
        guard let text = source.extractedText else { return }
        let item = ClipboardItem(
            content: .text(text), contentType: .plainText,
            sourceAppName: source.sourceAppName, sourceAppBundleID: source.sourceAppBundleID,
            isSensitive: source.isSensitive, containsSecret: source.containsSecret
        )
        performProtectedRead(for: [item], reason: "Copy hidden extracted text") { [weak self] in
            self?.writeGeneratedTextItem(item)
        }
    }

    /// Capture before presenting clipboard UI. Preserve the target when moving between Clipped windows.
    func captureFrontmostApp() {
        guard let frontmost = pasteBackEnvironment.frontmostApplication else {
            previousActiveApp = nil
            return
        }
        guard frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        previousActiveApp = frontmost.isTerminated ? nil : frontmost
    }

    @discardableResult
    func pasteMatchingStyle(_ item: ClipboardItem) -> Task<Void, Never>? {
        pasteToActiveApp(item, asPlainText: true)
    }

    private static let pasteActivationCheckLimit = 25

    /// Copy, dismiss the panel, and paste only after the captured app regains focus.
    @discardableResult
    func pasteToActiveApp(_ item: ClipboardItem, asPlainText: Bool = false) -> Task<Void, Never>? {
        let target = previousActiveApp
        let environment = pasteBackEnvironment
        // Pasting remains the frictionless clipboard workflow in every secret-handling mode.
        writeToClipboard(item, asPlainText: asPlainText)
        dismissPanelForPaste?()
        guard let target, !target.isTerminated else { return nil }
        return Task {
            guard !Task.isCancelled, !environment.isSecureInputEnabled, target.activateForPaste() else { return }
            for _ in 0..<Self.pasteActivationCheckLimit {
                do {
                    try await environment.waitForActivation()
                } catch {
                    return
                }
                guard !Task.isCancelled, !target.isTerminated, !environment.isSecureInputEnabled else { return }
                guard environment.frontmostApplication?.processIdentifier == target.processIdentifier else { continue }
                environment.postPaste()
                return
            }
        }
    }

    func copyAsMarkdown(_ item: ClipboardItem) {
        copyToClipboard(item, as: .markdown)
    }

    func reveal(_ item: ClipboardItem, completion: @escaping @MainActor @Sendable () -> Void) {
        performProtectedRead(for: [item], reason: "Reveal hidden clipboard content", action: completion)
    }

    private func performExplicitSecretAction(
        for item: ClipboardItem,
        reason: String,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        performAuthenticatedAction(
            required: requiresAuthenticationForSecretAccess(item), reason: reason, action: action
        )
    }

    private func performProtectedRead(
        for items: [ClipboardItem],
        reason: String,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        let required = items.contains { $0.isSensitive || requiresAuthenticationForSecretAccess($0) }
        performAuthenticatedAction(required: required, reason: reason, action: action)
    }

    private func performAuthenticatedAction(
        required: Bool,
        reason: String,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        guard required else {
            action()
            return
        }
        authenticateSecretAccess(reason) { success in
            if success {
                action()
            }
        }
    }

    private func requiresAuthenticationForSecretAccess(_ item: ClipboardItem) -> Bool {
        item.containsSecret && settingsManager?.secretHandling == .requireAuthentication
    }

    func exportItems(_ items: [ClipboardItem]) {
        let contributors = items.filter { $0.plainText != nil }
        guard !contributors.isEmpty else { return }
        performProtectedRead(for: contributors, reason: "Export hidden clipboard content") { [self] in
            let merged = contributors.compactMap(\.plainText).joined(separator: "\n\n---\n\n")
            guard !merged.isEmpty else { return }

            monitor.write { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString(merged, forType: .string)
            }
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

    /// Authorize "Save as…" before exposing a filename or export bytes.
    func prepareFileExport(
        for item: ClipboardItem,
        format: ExportFormat,
        completion: @escaping @MainActor @Sendable (PreparedFileExport) -> Void
    ) {
        let render = renderExportData
        performProtectedRead(for: [item], reason: "Save hidden clipboard content") {
            completion(PreparedFileExport(
                suggestedFilename: "\(FileExporter.suggestedBaseName(for: item)).\(format.fileExtension)",
                encode: { render(item, format) }
            ))
        }
    }

    /// Materialize an image as a temporary PNG and open it explicitly in Preview.
    func openImageInPreview(_ item: ClipboardItem) {
        performProtectedRead(for: [item], reason: "Preview hidden clipboard content") { [weak self] in
            guard let self else { return }
            do {
                try previewImage(item)
            } catch {
                Self.logger.error("Opening image in Preview failed: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
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
            ClipboardPasteboardWriter.write(result, to: pasteboard)
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

@MainActor
struct PreparedFileExport {
    let suggestedFilename: String
    private let encode: () -> Data?

    fileprivate init(suggestedFilename: String, encode: @escaping () -> Data?) {
        self.suggestedFilename = suggestedFilename
        self.encode = encode
    }

    func data() -> Data? {
        encode()
    }
}

@MainActor
protocol PasteBackApplication: AnyObject {
    var bundleIdentifier: String? { get }
    var processIdentifier: pid_t { get }
    var isTerminated: Bool { get }
    @discardableResult func activateForPaste() -> Bool
}

extension NSRunningApplication: PasteBackApplication {
    func activateForPaste() -> Bool {
        NSApp.yieldActivation(to: self)
        return activate(from: .current, options: [])
    }
}

@MainActor
protocol PasteBackEnvironment {
    var frontmostApplication: (any PasteBackApplication)? { get }
    var isSecureInputEnabled: Bool { get }
    func waitForActivation() async throws
    func postPaste()
}

@MainActor
struct WorkspacePasteBackEnvironment: PasteBackEnvironment {
    var frontmostApplication: (any PasteBackApplication)? {
        NSWorkspace.shared.frontmostApplication
    }

    var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    func waitForActivation() async throws {
        try await Task.sleep(for: .milliseconds(20))
    }

    func postPaste() {
        guard !isSecureInputEnabled else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let pasteKeyCode: UInt16 = 0x09
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

/// Bounds concurrent enrichment and keeps each permit scoped to its operation.
actor TaskLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let limit: Int
    private var running = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func withPermit<Result: Sendable>(_ operation: @Sendable () async throws -> Result) async throws -> Result {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
        // A release may hand us a slot before the cancellation handler reaches the actor.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            running = max(0, running - 1)
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}
