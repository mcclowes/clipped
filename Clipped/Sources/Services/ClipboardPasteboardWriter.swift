import AppKit

/// Encodes clipboard content without owning authorization, monitoring, or history updates.
@MainActor
enum ClipboardPasteboardWriter {
    private struct RepresentationOutput {
        let type: NSPasteboard.PasteboardType
        let data: Data?
        let text: String
    }

    static func write(
        _ item: ClipboardItem,
        asPlainText: Bool = false,
        to pasteboard: any PasteboardProtocol
    ) {
        pasteboard.clearContents()
        if !asPlainText, let customTypes = item.customPasteboardTypes {
            for (rawType, data) in customTypes {
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return
        }

        switch item.content {
        case let .text(string):
            pasteboard.setString(string, forType: .string)
        case let .richText(rtfData, plain):
            writeRichText(
                rtfData: rtfData, plain: plain, htmlData: item.htmlData,
                asPlainText: asPlainText, to: pasteboard
            )
        case let .url(url):
            pasteboard.setString(url.absoluteString, forType: .string)
        case let .image(data, _):
            writeImageData(data, to: pasteboard)
        case let .svg(data, _):
            // Keep vector data for design tools, markup for editors, and TIFF for other apps.
            if let markup = String(data: data, encoding: .utf8) {
                pasteboard.setString(markup, forType: .string)
            }
            pasteboard.setData(data, forType: svgPasteboardType)
            if let tiff = NSImage(data: data)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        }
    }

    static func write(
        _ item: ClipboardItem,
        as representation: ClipboardRepresentation,
        to pasteboard: any PasteboardProtocol
    ) {
        guard case let .richText(rtfData, plain) = item.content else {
            write(item, asPlainText: true, to: pasteboard)
            return
        }

        let output = switch representation {
        case .html:
            RepresentationOutput(type: ClipboardRepresentation.html.pasteboardType, data: item.htmlData, text: plain)
        case .richText:
            RepresentationOutput(type: .rtf, data: rtfData, text: plain)
        case .plainText:
            RepresentationOutput(type: .string, data: nil, text: plain)
        case .markdown:
            RepresentationOutput(
                type: .string, data: nil,
                text: MarkdownConverter.convert(rtfData: rtfData).flatMap { $0.isEmpty ? nil : $0 } ?? plain
            )
        }

        pasteboard.clearContents()
        if let data = output.data {
            pasteboard.setData(data, forType: output.type)
        }
        pasteboard.setString(output.text, forType: .string)
    }

    private static func writeRichText(
        rtfData: Data,
        plain: String,
        htmlData: Data?,
        asPlainText: Bool,
        to pasteboard: any PasteboardProtocol
    ) {
        guard !asPlainText else {
            pasteboard.setString(plain, forType: .string)
            return
        }
        pasteboard.setData(rtfData, forType: .rtf)
        pasteboard.setString(plain, forType: .string)
        if let htmlData {
            pasteboard.setData(htmlData, forType: ClipboardRepresentation.html.pasteboardType)
        }
    }

    private static func isPNGData(_ data: Data) -> Bool {
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= magic.count else { return false }
        return data.prefix(magic.count).elementsEqual(magic)
    }

    private static func isTIFFData(_ data: Data) -> Bool {
        let little: [UInt8] = [0x49, 0x49, 0x2A, 0x00]
        let big: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A]
        guard data.count >= 4 else { return false }
        let head = data.prefix(4)
        return head.elementsEqual(little) || head.elementsEqual(big)
    }

    private static func writeImageData(_ data: Data, to pasteboard: any PasteboardProtocol) {
        if isPNGData(data) {
            pasteboard.setData(data, forType: .png)
            return
        }
        if isTIFFData(data) {
            pasteboard.setData(data, forType: .tiff)
            return
        }
        if let tiff = NSImage(data: data)?.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }
}
