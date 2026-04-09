import AppKit
import Carbon
import Observation
import SwiftUI

private let codeEditorBundleIDs: Set<String> = [
    "com.microsoft.VSCode",
    "com.apple.dt.Xcode",
    "com.sublimetext.4",
    "com.jetbrains.intellij",
    "dev.zed.Zed",
    "com.todesktop.230313mzl4w4u92", // Cursor
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
    var items: [ClipboardItem] = []
    var pinnedItems: [ClipboardItem] = []
    var searchQuery = ""
    var selectedContentType: ContentType?
    var openedViaHotkey = false

    var settingsManager: SettingsManager?

    private(set) var isMonitoring = false
    private var pollTimer: Timer?
    private var lastChangeCount: Int = 0

    static let maxHistorySize = 10

    var filteredItems: [ClipboardItem] {
        var result = items
        if let type = selectedContentType {
            result = result.filter { $0.contentType == type }
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
        let (loaded, pinned) = HistoryStore.shared.load()
        if items.isEmpty { items = loaded }
        if pinnedItems.isEmpty { pinnedItems = pinned }
    }

    func saveHistory() {
        guard settingsManager?.persistAcrossReboots == true else { return }
        HistoryStore.shared.save(items: items, pinnedItems: pinnedItems)
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func checkClipboard() {
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

        guard let item = readClipboardItem(
            from: pasteboard,
            appName: frontmostApp?.localizedName,
            bundleID: bundleID
        ) else { return }

        if isFromPasswordManager, secureMode {
            item.isSensitive = true
        }

        // Deduplicate: remove existing item with same content preview
        items.removeAll { $0.preview == item.preview && !$0.isPinned }

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

        // Fetch link title for URLs
        if case let .url(url) = item.content {
            Task {
                item.linkTitle = await LinkMetadataFetcher.shared.fetchTitle(for: url)
            }
        }

        // Trim to max size (excluding pinned)
        while items.count(where: { !$0.isPinned }) > Self.maxHistorySize {
            if let lastUnpinned = items.lastIndex(where: { !$0.isPinned }) {
                items.remove(at: lastUnpinned)
            }
        }

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
            let isCode = bundleID.map { codeEditorBundleIDs.contains($0) } ?? false
            return ClipboardItem(
                content: .text(string),
                contentType: isCode ? .code : .plainText,
                sourceAppName: appName,
                sourceAppBundleID: bundleID
            )
        }

        return nil
    }

    // MARK: - Actions

    func copyToClipboard(_ item: ClipboardItem, asPlainText: Bool = false) {
        stopMonitoring()
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

        lastChangeCount = pasteboard.changeCount

        if settingsManager?.playSoundOnCopy ?? true {
            NSSound(named: "Pop")?.play()
        }

        // Move item to top
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let moved = items.remove(at: index)
            items.insert(moved, at: 0)
        }

        // Resume monitoring after a brief delay
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            startMonitoring()
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

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
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

        stopMonitoring()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown.isEmpty ? plain : markdown, forType: .string)
        lastChangeCount = pasteboard.changeCount

        Task {
            try? await Task.sleep(for: .milliseconds(200))
            startMonitoring()
        }
    }

    func exportItems(_ items: [ClipboardItem]) {
        let merged = items.compactMap(\.plainText).joined(separator: "\n\n---\n\n")
        guard !merged.isEmpty else { return }

        stopMonitoring()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(merged, forType: .string)
        lastChangeCount = pasteboard.changeCount

        Task {
            try? await Task.sleep(for: .milliseconds(200))
            startMonitoring()
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
}
