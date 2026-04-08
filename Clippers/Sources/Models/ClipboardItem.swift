import AppKit
import Foundation

enum ContentType: String, CaseIterable, Identifiable, Sendable {
    case plainText = "Text"
    case richText = "Rich Text"
    case url = "URL"
    case code = "Code"
    case image = "Image"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .plainText: "doc.text"
        case .richText: "doc.richtext"
        case .url: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        }
    }
}

@MainActor
final class ClipboardItem: Identifiable, Sendable {
    let id: UUID
    let content: ClipboardContent
    let contentType: ContentType
    let sourceAppName: String?
    let sourceAppBundleID: String?
    let timestamp: Date
    var isPinned: Bool

    var plainText: String? {
        switch content {
        case .text(let string): string
        case .richText(_, let plainFallback): plainFallback
        case .url(let url): url.absoluteString
        default: nil
        }
    }

    var preview: String {
        switch content {
        case .text(let string):
            String(string.prefix(200))
        case .richText(_, let plain):
            String(plain.prefix(200))
        case .url(let url):
            url.absoluteString
        case .image(_, let size):
            "Image — \(Int(size.width))×\(Int(size.height))"
        }
    }

    init(
        content: ClipboardContent,
        contentType: ContentType,
        sourceAppName: String? = nil,
        sourceAppBundleID: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = UUID()
        self.content = content
        self.contentType = contentType
        self.sourceAppName = sourceAppName
        self.sourceAppBundleID = sourceAppBundleID
        self.timestamp = Date()
        self.isPinned = isPinned
    }
}

enum ClipboardContent: Sendable {
    case text(String)
    case richText(Data, String) // RTF data + plain text fallback
    case url(URL)
    case image(Data, CGSize) // image data + dimensions
}
