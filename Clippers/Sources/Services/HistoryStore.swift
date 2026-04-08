import AppKit
import Foundation

/// Persists clipboard history to a JSON file in the app's support directory.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("Clippers", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.fileURL = appDir.appendingPathComponent("history.json")
    }

    func save(items: [ClipboardItem], pinnedItems: [ClipboardItem]) {
        let entries = (items + pinnedItems).map { StoredEntry(from: $0) }
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Silently fail — persistence is optional
        }
    }

    func load() -> (items: [ClipboardItem], pinned: [ClipboardItem]) {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([StoredEntry].self, from: data)
        else {
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
        self.contentType = item.contentType.rawValue
        self.sourceAppName = item.sourceAppName
        self.sourceAppBundleID = item.sourceAppBundleID
        self.timestamp = item.timestamp
        self.isPinned = item.isPinned
        self.linkTitle = item.linkTitle

        switch item.content {
        case .text(let string):
            self.textContent = string
            self.rtfData = nil
            self.urlString = nil
            self.imageData = nil
            self.imageWidth = nil
            self.imageHeight = nil
        case .richText(let data, let plain):
            self.textContent = plain
            self.rtfData = data
            self.urlString = nil
            self.imageData = nil
            self.imageWidth = nil
            self.imageHeight = nil
        case .url(let url):
            self.textContent = nil
            self.rtfData = nil
            self.urlString = url.absoluteString
            self.imageData = nil
            self.imageWidth = nil
            self.imageHeight = nil
        case .image(let data, let size):
            self.textContent = nil
            self.rtfData = nil
            self.urlString = nil
            self.imageData = data
            self.imageWidth = size.width
            self.imageHeight = size.height
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
            content: content,
            contentType: type,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID,
            isPinned: isPinned
        )
        item.linkTitle = linkTitle
        return item
    }
}
