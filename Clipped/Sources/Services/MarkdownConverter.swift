import AppKit
import Foundation

enum MarkdownConverter {
    /// Converts RTF data to a basic Markdown string.
    /// Handles bold, italic, bold+italic, and links.
    static func convert(rtfData: Data) -> String? {
        guard let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil) else {
            return nil
        }
        return convert(attributedString: attributed)
    }

    static func convert(attributedString: NSAttributedString) -> String {
        var result = ""
        let fullRange = NSRange(location: 0, length: attributedString.length)

        attributedString.enumerateAttributes(in: fullRange) { attributes, range, _ in
            let substring = (attributedString.string as NSString).substring(with: range)

            var text = substring

            // Check for link
            if let url = attributes[.link] as? URL {
                text = "[\(text)](\(url.absoluteString))"
            } else if let urlString = attributes[.link] as? String {
                text = "[\(text)](\(urlString))"
            }

            // Check font traits for bold/italic
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                let isBold = traits.contains(.bold)
                let isItalic = traits.contains(.italic)

                if isBold, isItalic {
                    text = "***\(text)***"
                } else if isBold {
                    text = "**\(text)**"
                } else if isItalic {
                    text = "*\(text)*"
                }
            }

            result += text
        }

        return result
    }
}
