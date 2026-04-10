import AppKit
import Foundation
import os

protocol HistoryStoring: Sendable {
    func save(entries: [StoredEntry]) async
    func load() async -> [StoredEntry]
    func clear() async
}

/// Persists clipboard history to disk. Metadata lives in `history.json`; image payloads
/// are stored as individual files under `images/<uuid>.{png,tiff}` so the JSON doesn't
/// carry base64-bloated images (a 4 MB screenshot was ~5.4 MB encoded). Disk I/O is
/// isolated to this actor so callers on the main actor never block the UI.
actor HistoryStore: HistoryStoring {
    static let shared = HistoryStore()

    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "HistoryStore")

    private let fileURL: URL
    private let imagesDir: URL

    init() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            fatalError("Application Support directory not found")
        }
        let appDir = appSupport.appendingPathComponent("Clipped", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        fileURL = appDir.appendingPathComponent("history.json")
        imagesDir = appDir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    func save(entries: [StoredEntry]) async {
        // Write image payloads to their own files and build wire entries with imageData
        // stripped so the JSON stays small.
        var wireEntries: [StoredEntry] = []
        wireEntries.reserveCapacity(entries.count)
        var liveImageIDs: Set<UUID> = []

        for entry in entries {
            if let data = entry.imageData {
                let url = imageFileURL(for: entry.id, data: data)
                writeImageFile(data: data, to: url)
                liveImageIDs.insert(entry.id)
            }
            wireEntries.append(entry.strippingImageData())
        }

        deleteOrphanedImageFiles(keeping: liveImageIDs)

        do {
            let data = try JSONEncoder().encode(wireEntries)
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

        let decoded: [StoredEntry]
        do {
            decoded = try JSONDecoder().decode([StoredEntry].self, from: data)
        } catch {
            Self.logger.error("History file corrupted, backing up and starting fresh: \(error.localizedDescription)")
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("history.corrupted.json")
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            return []
        }

        // Hydrate image payloads from the side files. If a legacy history.json still has
        // imageData embedded, pass it through untouched — the next save() will migrate it
        // to a side file.
        return decoded.map { entry in
            guard entry.contentType == "Image", entry.imageData == nil else { return entry }
            guard let payload = loadImageFile(for: entry.id) else { return entry }
            return entry.withImageData(payload)
        }
    }

    func clear() async {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: imagesDir)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    // MARK: - Image files

    private func imageFileURL(for id: UUID, data: Data) -> URL {
        let ext = Self.isPNGData(data) ? "png" : "tiff"
        return imagesDir.appendingPathComponent("\(id.uuidString).\(ext)")
    }

    private func loadImageFile(for id: UUID) -> Data? {
        for ext in ["png", "tiff"] {
            let url = imagesDir.appendingPathComponent("\(id.uuidString).\(ext)")
            if let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }

    private func writeImageFile(data: Data, to url: URL) {
        FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
    }

    /// Remove any image files on disk whose UUID is no longer in the live set.
    private func deleteOrphanedImageFiles(keeping liveIDs: Set<UUID>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: imagesDir,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in entries {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: stem) else { continue }
            if !liveIDs.contains(id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func isPNGData(_ data: Data) -> Bool {
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= magic.count else { return false }
        return data.prefix(magic.count).elementsEqual(magic)
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
    /// Nullable for backward compat with v1 history files that predate content categories.
    let detectedCategories: [String]?

    /// Copy of this entry with `imageData` cleared, used when writing the JSON envelope
    /// so a 4 MB screenshot doesn't round-trip as base64 inside the history file.
    func strippingImageData() -> StoredEntry {
        StoredEntry(
            id: id,
            contentType: contentType,
            textContent: textContent,
            rtfData: rtfData,
            urlString: urlString,
            imageData: nil,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID,
            timestamp: timestamp,
            isPinned: isPinned,
            isDeveloperContent: isDeveloperContent,
            linkTitle: linkTitle,
            linkFavicon: linkFavicon,
            mutationsApplied: mutationsApplied,
            detectedCategories: detectedCategories
        )
    }

    /// Copy of this entry with `imageData` hydrated from disk during load.
    func withImageData(_ data: Data) -> StoredEntry {
        StoredEntry(
            id: id,
            contentType: contentType,
            textContent: textContent,
            rtfData: rtfData,
            urlString: urlString,
            imageData: data,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID,
            timestamp: timestamp,
            isPinned: isPinned,
            isDeveloperContent: isDeveloperContent,
            linkTitle: linkTitle,
            linkFavicon: linkFavicon,
            mutationsApplied: mutationsApplied,
            detectedCategories: detectedCategories
        )
    }
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
            mutationsApplied: item.mutationsApplied.isEmpty ? nil : item.mutationsApplied,
            detectedCategories: item.detectedCategories.isEmpty
                ? nil
                : item.detectedCategories.map(\.rawValue).sorted()
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

        let decodedCategories: Set<ContentCategory> = Set(
            (detectedCategories ?? []).compactMap(ContentCategory.init(rawValue:))
        )
        let item = ClipboardItem(
            id: id,
            content: content,
            contentType: type,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID,
            timestamp: timestamp,
            isPinned: isPinned,
            isDeveloperContent: isDeveloperContent ?? false,
            detectedCategories: decodedCategories
        )
        item.linkTitle = linkTitle
        item.linkFavicon = linkFavicon
        item.mutationsApplied = mutationsApplied ?? []
        return item
    }
}
