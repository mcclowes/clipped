import AppKit
import Foundation
import os

protocol HistoryStoring: Sendable {
    func save(entries: [StoredEntry]) async
    func load() async -> [StoredEntry]
    func clear() async
}

/// Persists clipboard history to a JSON file in the app's support directory.
/// Disk I/O is isolated to this actor so callers on the main actor never block the UI.
actor HistoryStore: HistoryStoring {
    static let shared = HistoryStore()

    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "HistoryStore")

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

    func save(entries: [StoredEntry]) async {
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
            _ = try FileManager.default.replaceItemAt(
                fileURL,
                withItemAt: tempURL,
                options: .usingNewMetadataOnly
            )
        } catch {
            Self.logger.error("Failed to save clipboard history: \(error.localizedDescription)")
        }
    }

    func load() async -> [StoredEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            Self.logger.error("Failed to read history file: \(error.localizedDescription)")
            return []
        }

        do {
            return try JSONDecoder().decode([StoredEntry].self, from: data)
        } catch {
            Self.logger.error("History file corrupted, backing up and starting fresh: \(error.localizedDescription)")
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("history.corrupted.json")
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            return []
        }
    }

    func clear() async {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Codable storage model

/// Serialization-friendly snapshot of a ClipboardItem. Conversions that touch
/// ClipboardItem live in a @MainActor extension so this struct itself is Sendable
/// by default (all stored properties are value types).
struct StoredEntry: Codable {
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
    let isDeveloperContent: Bool?
    let linkTitle: String?
    let linkFavicon: Data?
    let mutationsApplied: [String]?
}

@MainActor
extension StoredEntry {
    init(item: ClipboardItem) {
        let textContent: String?
        let rtfData: Data?
        let urlString: String?
        let imageData: Data?
        let imageWidth: Double?
        let imageHeight: Double?

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

        self.init(
            id: item.id,
            contentType: item.contentType.rawValue,
            textContent: textContent,
            rtfData: rtfData,
            urlString: urlString,
            imageData: imageData,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            sourceAppName: item.sourceAppName,
            sourceAppBundleID: item.sourceAppBundleID,
            timestamp: item.timestamp,
            isPinned: item.isPinned,
            isDeveloperContent: item.isDeveloperContent,
            linkTitle: item.linkTitle,
            linkFavicon: item.linkFavicon,
            mutationsApplied: item.mutationsApplied.isEmpty ? nil : item.mutationsApplied
        )
    }

    func toClipboardItem() -> ClipboardItem? {
        // Map legacy "Code" type to plainText
        let resolvedType = contentType == "Code" ? "Text" : contentType
        guard let type = ContentType(rawValue: resolvedType) else { return nil }

        let content: ClipboardContent
        switch type {
        case .plainText:
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
            isPinned: isPinned,
            isDeveloperContent: isDeveloperContent ?? false
        )
        item.linkTitle = linkTitle
        item.linkFavicon = linkFavicon
        item.mutationsApplied = mutationsApplied ?? []
        return item
    }
}
