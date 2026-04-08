import AppKit
import Observation
import SwiftUI

private let codeEditorBundleIDs: Set<String> = [
    "com.microsoft.VSCode",
    "com.apple.dt.Xcode",
    "com.sublimetext.4",
    "com.jetbrains.intellij",
    "dev.zed.Zed",
    "com.todesktop.230313mzl4w4u92",  // Cursor
]

private let passwordManagerBundleIDs: Set<String> = [
    "com.agilebits.onepassword7",
    "com.agilebits.onepassword-osx",
    "com.lastpass.LastPass",
    "com.bitwarden.desktop",
    "org.keepassxc.keepassxc",
]

@MainActor
@Observable
final class ClipboardManager {
    var items: [ClipboardItem] = []
    var pinnedItems: [ClipboardItem] = []
    var searchQuery = ""
    var selectedContentType: ContentType?

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

        // Secure mode: skip items from password managers
        if let bundleID, passwordManagerBundleIDs.contains(bundleID) {
            return
        }

        guard let item = readClipboardItem(
            from: pasteboard,
            appName: frontmostApp?.localizedName,
            bundleID: bundleID
        ) else { return }

        // Deduplicate: remove existing item with same content preview
        items.removeAll { $0.preview == item.preview && !$0.isPinned }

        items.insert(item, at: 0)

        // Fetch link title for URLs
        if case .url(let url) = item.content {
            Task {
                item.linkTitle = await LinkMetadataFetcher.shared.fetchTitle(for: url)
            }
        }

        // Trim to max size (excluding pinned)
        while items.filter({ !$0.isPinned }).count > Self.maxHistorySize {
            if let lastUnpinned = items.lastIndex(where: { !$0.isPinned }) {
                items.remove(at: lastUnpinned)
            }
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
        case .text(let string):
            pasteboard.setString(string, forType: .string)
        case .richText(let rtfData, let plain):
            if asPlainText {
                pasteboard.setString(plain, forType: .string)
            } else {
                pasteboard.setData(rtfData, forType: .rtf)
                pasteboard.setString(plain, forType: .string)
            }
        case .url(let url):
            pasteboard.setString(url.absoluteString, forType: .string)
        case .image(let data, _):
            pasteboard.setData(data, forType: .tiff)
        }

        lastChangeCount = pasteboard.changeCount

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
        copyToClipboard(item, asPlainText: true)

        Task {
            try? await Task.sleep(for: .milliseconds(100))
            simulatePaste()
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    func copyAsMarkdown(_ item: ClipboardItem) {
        guard case .richText(let rtfData, let plain) = item.content,
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
        let merged = items.compactMap { $0.plainText }.joined(separator: "\n\n---\n\n")
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
    }

    func removeItem(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        pinnedItems.removeAll { $0.id == item.id }
    }

    func clearAll(includePinned: Bool = false) {
        items.removeAll()
        if includePinned {
            pinnedItems.removeAll()
        }
    }
}
