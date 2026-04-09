import AppKit
import Foundation
import os

@MainActor
protocol HistoryStoring: AnyObject {
    func save(items: [ClipboardItem], pinnedItems: [ClipboardItem])
    func load() -> (items: [ClipboardItem], pinned: [ClipboardItem])
    func clear()
}

/// Persists clipboard history to a JSON file in the app's support directory.
@MainActor
final class HistoryStore: HistoryStoring {
    static let shared = HistoryStore()

    private static let logger = Logger(subsystem: "com.mcclowes.Clipped", category: "HistoryStore")

    private let fileURL: URL

    init() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            fatalError("Application Support directory not found")
        }
        let appDir = appSupport.appendingPathComponent("Clipped", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        fileURL = appDir.appendingPathComponent("history.json")
    }

    func save(items: [ClipboardItem], pinnedItems: [ClipboardItem]) {
        let entries = (items + pinnedItems).filter { !$0.isSensitive }.map { StoredEntry(from: $0) }
        do {
            let data = try JSONEncoder().encode(entries)
            // Write to a temp file with restricted permissions, then atomically move into place.
            // This avoids the race where .atomic creates a world-readable temp file.
            let tempURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("history.tmp.json")
            FileManager.default.createFile(
                atPath: tempURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            Self.logger.error("Failed to save clipboard history: \(error.localizedDescription)")
        }
    }

    func load() -> (items: [ClipboardItem], pinned: [ClipboardItem]) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ([], [])
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            Self.logger.error("Failed to read history file: \(error.localizedDescription)")
            return ([], [])
        }

        let entries: [StoredEntry]
        do {
            entries = try JSONDecoder().decode([StoredEntry].self, from: data)
        } catch {
            Self.logger.error("History file corrupted, backing up and starting fresh: \(error.localizedDescription)")
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("history.corrupted.json")
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            return ([], [])
        }

        var items: [ClipboardItem] = []
        var pinned: [ClipboardItem] = []

        for entry in entries {
            guard let item = entry.toClipboardItem() else { continue }
            if item.isPinned {
                pinned.append(item)
            } else {
                items.append(item)
            }
        }

        return (items, pinned)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Codable storage model

@MainActor
private struct StoredEntry: Codable {
    let id: UUID
    let contentType: String
    let textContent: String?
    let rtfData: Data?
    let urlString: String?
    let imageData: Data?
    let imageWidth: Double?
    let imageHeight: Double?
    let sourceAppName: String?
    let sourceAppBundleID: String?
    let timestamp: Date
    let isPinned: Bool
    let linkTitle: String?

    init(from item: ClipboardItem) {
        id = item.id
        contentType = item.contentType.rawValue
        sourceAppName = item.sourceAppName
        sourceAppBundleID = item.sourceAppBundleID
        timestamp = item.timestamp
        isPinned = item.isPinned
        linkTitle = item.linkTitle

        switch item.content {
        case let .text(string):
            textContent = string
            rtfData = nil
            urlString = nil
            imageData = nil
            imageWidth = nil
            imageHeight = nil
        case let .richText(data, plain):
            textContent = plain
            rtfData = data
            urlString = nil
            imageData = nil
            imageWidth = nil
            imageHeight = nil
        case let .url(url):
            textContent = nil
            rtfData = nil
            urlString = url.absoluteString
            imageData = nil
            imageWidth = nil
            imageHeight = nil
        case let .image(data, size):
            textContent = nil
            rtfData = nil
            urlString = nil
            imageData = data
            imageWidth = size.width
            imageHeight = size.height
        }
    }

    func toClipboardItem() -> ClipboardItem? {
        guard let type = ContentType(rawValue: contentType) else { return nil }

        let content: ClipboardContent
        switch type {
        case .plainText, .code:
            guard let text = textContent else { return nil }
            content = .text(text)
        case .richText:
            if let rtf = rtfData, let plain = textContent {
                content = .richText(rtf, plain)
            } else if let text = textContent {
                content = .text(text)
            } else {
                return nil
            }
        case .url:
            guard let str = urlString, let url = URL(string: str) else { return nil }
            content = .url(url)
        case .image:
            guard let data = imageData else { return nil }
            let size = CGSize(width: imageWidth ?? 0, height: imageHeight ?? 0)
            content = .image(data, size)
        }

        let item = ClipboardItem(
            id: id,
            content: content,
            contentType: type,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID,
            timestamp: timestamp,
            isPinned: isPinned
        )
        item.linkTitle = linkTitle
        return item
    }
}
