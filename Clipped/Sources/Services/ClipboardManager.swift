import AppKit
import Carbon
import Observation
import os
import SwiftUI

private let codeEditorBundleIDs: Set<String> = [
    "com.microsoft.VSCode",
    "com.apple.dt.Xcode",
    "com.sublimetext.4",
    "com.jetbrains.intellij",
    "dev.zed.Zed",
    "com.todesktop.230313mzl4w4u92", // Cursor
]

private let terminalBundleIDs: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "io.alacritty",
    "com.github.wez.wezterm",
    "net.kovidgoyal.kitty",
]

private let passwordManagerBundleIDs: Set<String> = [
    "com.agilebits.onepassword7",
    "com.agilebits.onepassword-osx",
    "com.lastpass.LastPass",
    "com.bitwarden.desktop",
    "org.keepassxc.keepassxc",
]

/// Industry-standard pasteboard type set by password managers to mark concealed/sensitive content.
/// See https://nspasteboard.org
private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

@MainActor
@Observable
final class ClipboardManager {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "ClipboardManager")

    var items: [ClipboardItem] = []
    var pinnedItems: [ClipboardItem] = []
    var searchQuery = ""
    var selectedFilter: ClipboardFilter?
    var openedViaHotkey = false

    var settingsManager: (any SettingsManaging)?
    var historyStore: any HistoryStoring = HistoryStore.shared
    var linkMetadataFetcher: any LinkMetadataFetching = LinkMetadataFetcher.shared
    var mutationService: any ClipboardMutating = ClipboardMutationService()

    private(set) var isMonitoring = false
    private var pollTimer: Timer?
    private var lastChangeCount: Int = 0
    private var isCheckingClipboard = false
    private var resumeMonitoringTask: Task<Void, Never>?

    static let maxHistorySize = 50

    private static let pollInterval: TimeInterval = 0.5
    private static let monitoringResumeDelay: Duration = .milliseconds(200)
    private static let vKeyCode: UInt16 = 0x09

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

    var filteredPinnedItems: [ClipboardItem] {
        applyFilters(to: pinnedItems)
    }

    var filteredItems: [ClipboardItem] {
        applyFilters(to: items)
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

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        startMonitoring()
    }

    func loadPersistedHistory() {
        guard settingsManager?.persistAcrossReboots == true else { return }
        let (loaded, pinned) = historyStore.load()
        if items.isEmpty { items = loaded }
        if pinnedItems.isEmpty { pinnedItems = pinned }
    }

    func saveHistory() {
        guard settingsManager?.persistAcrossReboots == true else { return }
        historyStore.save(items: items, pinnedItems: pinnedItems)
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        Self.logger.debug("Starting clipboard monitoring")
        isMonitoring = true
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
    }

    func stopMonitoring() {
        Self.logger.debug("Stopping clipboard monitoring")
        isMonitoring = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Pause monitoring, perform a clipboard mutation, then resume after a brief delay.
    private func withMonitoringPaused(_ body: () -> Void) {
        resumeMonitoringTask?.cancel()
        stopMonitoring()
        body()
        lastChangeCount = NSPasteboard.general.changeCount
        resumeMonitoringTask = Task {
            try? await Task.sleep(for: Self.monitoringResumeDelay)
            guard !Task.isCancelled else { return }
            startMonitoring()
        }
    }

    private func checkClipboard() {
        guard !isCheckingClipboard else { return }
        isCheckingClipboard = true
        defer { isCheckingClipboard = false }
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmostApp?.bundleIdentifier

        let hasConcealedType = pasteboard.types?.contains(concealedType) ?? false
        let isFromPasswordManager = hasConcealedType
            || (bundleID.map { passwordManagerBundleIDs.contains($0) } ?? false)
        let secureMode = settingsManager?.secureMode ?? true
        let secureTimeout = settingsManager?.secureTimeout ?? 0

        // Secure mode: skip or auto-expire sensitive items
        if isFromPasswordManager, secureMode, secureTimeout == 0 {
            return
        }

        guard var item = readClipboardItem(
            from: pasteboard,
            appName: frontmostApp?.localizedName,
            bundleID: bundleID
        ) else { return }

        // Apply clipboard mutations (strip tracking params, trim whitespace, etc.)
        item = mutationService.apply(to: item, sourceAppBundleID: bundleID)

        // Always flag password manager items as sensitive so they're never persisted to disk,
        // regardless of whether secure mode UI behavior is enabled
        if isFromPasswordManager {
            item.isSensitive = true
        }

        // Deduplicate: remove existing item with same content
        items.removeAll { $0.content == item.content && !$0.isPinned }

        items.insert(item, at: 0)

        // Schedule auto-removal for password manager items — don't persist until removed
        let pendingRemoval = isFromPasswordManager && secureMode && secureTimeout > 0
        if pendingRemoval {
            let itemID = item.id
            Task {
                try? await Task.sleep(for: .seconds(secureTimeout))
                items.removeAll { $0.id == itemID }
                saveHistory()
            }
        }

        // Fetch link metadata (title + favicon) for URLs
        if case let .url(url) = item.content {
            Task {
                let metadata = await linkMetadataFetcher.fetchMetadata(for: url)
                item.linkTitle = metadata.title
                item.linkFavicon = metadata.favicon
                saveHistory()
            }
        }

        trimToMaxSize()

        if !pendingRemoval {
            saveHistory()
        }
    }

    private func readClipboardItem(
        from pasteboard: NSPasteboard,
        appName: String?,
        bundleID: String?
    ) -> ClipboardItem? {
        let types = pasteboard.types ?? []

        // Check for image first
        if types.contains(.tiff) || types.contains(.png) {
            if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
                if let image = NSImage(data: imageData) {
                    return ClipboardItem(
                        content: .image(imageData, image.size),
                        contentType: .image,
                        sourceAppName: appName,
                        sourceAppBundleID: bundleID
                    )
                }
            }
        }

        // Check for URL
        if types.contains(.URL), let url = URL(string: pasteboard.string(forType: .string) ?? "") {
            if url.scheme == "http" || url.scheme == "https" {
                return ClipboardItem(
                    content: .url(url),
                    contentType: .url,
                    sourceAppName: appName,
                    sourceAppBundleID: bundleID
                )
            }
        }

        // Check for rich text
        if types.contains(.rtf), let rtfData = pasteboard.data(forType: .rtf) {
            let plainText = pasteboard.string(forType: .string) ?? ""
            return ClipboardItem(
                content: .richText(rtfData, plainText),
                contentType: .richText,
                sourceAppName: appName,
                sourceAppBundleID: bundleID
            )
        }

        // Plain text / code
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            // Detect URLs pasted as plain text (no .URL pasteboard type)
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.contains(" "), !trimmed.contains("\n"),
               let url = URL(string: trimmed),
               url.scheme == "http" || url.scheme == "https"
            {
                return ClipboardItem(
                    content: .url(url),
                    contentType: .url,
                    sourceAppName: appName,
                    sourceAppBundleID: bundleID
                )
            }

            let isFromCodeEditor = bundleID.map { codeEditorBundleIDs.contains($0) } ?? false
            let isFromTerminal = bundleID.map { terminalBundleIDs.contains($0) } ?? false
            let isDevContent = isFromCodeEditor || isFromTerminal
                || DeveloperContentDetector.isDeveloperContent(string)
            return ClipboardItem(
                content: .text(string),
                contentType: .plainText,
                sourceAppName: appName,
                sourceAppBundleID: bundleID,
                isDeveloperContent: isDevContent
            )
        }

        return nil
    }

    // MARK: - Actions

    func copyToClipboard(_ item: ClipboardItem, asPlainText: Bool = false) {
        withMonitoringPaused {
            let pasteboard = NSPasteboard.general
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
                pasteboard.setData(data, forType: .tiff)
            }
        }

        if settingsManager?.playSoundOnCopy ?? true {
            NSSound(named: "Pop")?.play()
        }

        // Move item to top
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let moved = items.remove(at: index)
            items.insert(moved, at: 0)
        }
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

        withMonitoringPaused {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(markdown.isEmpty ? plain : markdown, forType: .string)
        }
    }

    func exportItems(_ items: [ClipboardItem]) {
        let merged = items.compactMap(\.plainText).joined(separator: "\n\n---\n\n")
        guard !merged.isEmpty else { return }

        withMonitoringPaused {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(merged, forType: .string)
        }
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

    func restoreOriginal(_ item: ClipboardItem) {
        guard let original = item.originalContent else { return }
        item.content = original
        item.originalContent = nil
        item.mutationsApplied = []
        saveHistory()
    }

    func removeItem(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        pinnedItems.removeAll { $0.id == item.id }
        saveHistory()
    }

    func clearAll(includePinned: Bool = false) {
        items.removeAll()
        if includePinned {
            pinnedItems.removeAll()
        }
        saveHistory()
    }

    /// Remove oldest unpinned items beyond the configured max history size.
    /// Pinned and developer-content items are exempt from the cap.
    func trimToMaxSize() {
        let limit = settingsManager?.maxHistorySize ?? Self.maxHistorySize
        while items.count(where: { !$0.isPinned && !$0.isDeveloperContent }) > limit {
            if let lastTrimmable = items.lastIndex(where: { !$0.isPinned && !$0.isDeveloperContent }) {
                items.remove(at: lastTrimmable)
            }
        }
    }
}
