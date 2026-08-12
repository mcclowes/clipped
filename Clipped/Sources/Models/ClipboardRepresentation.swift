import AppKit

enum ClipboardRepresentation: String, CaseIterable, Identifiable {
    case html
    case richText
    case plainText
    case markdown

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .html:
            "HTML"
        case .richText:
            "Rich text (RTF)"
        case .plainText:
            "Plain text"
        case .markdown:
            "Markdown"
        }
    }

    var pasteboardType: NSPasteboard.PasteboardType {
        switch self {
        case .html:
            NSPasteboard.PasteboardType("public.html")
        case .richText:
            .rtf
        case .plainText, .markdown:
            .string
        }
    }
}
