import AppKit
import Foundation

/// Produces a set of example clipboard items shown on first launch so new users can see
/// what Clipped stores without needing to copy anything first. Runs exactly once per
/// install — a flag in `UserDefaults` gates subsequent launches.
enum OnboardingSeeder {
    static let didSeedDefaultsKey = "hasSeededOnboardingExamples"

    static func shouldSeed(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: didSeedDefaultsKey)
    }

    static func markSeeded(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: didSeedDefaultsKey)
    }

    /// Build the example items in display order (newest first). Timestamps are staggered
    /// by one second so the ordering survives any stable sort the UI applies later.
    @MainActor
    static func makeSeedItems(now: Date = Date()) -> [ClipboardItem] {
        var items: [ClipboardItem] = []

        items.append(
            ClipboardItem(
                content: .text(plainTextSample),
                contentType: .plainText,
                sourceAppName: sourceAppName,
                timestamp: now.addingTimeInterval(-1)
            )
        )

        if let rich = makeSampleRichText() {
            items.append(
                ClipboardItem(
                    content: .richText(rich.data, rich.plain),
                    contentType: .richText,
                    sourceAppName: sourceAppName,
                    timestamp: now.addingTimeInterval(-2)
                )
            )
        }

        if let url = URL(string: "https://github.com/mcclowes/clipped") {
            let item = ClipboardItem(
                content: .url(url),
                contentType: .url,
                sourceAppName: sourceAppName,
                timestamp: now.addingTimeInterval(-3)
            )
            item.linkTitle = "Clipped on GitHub"
            items.append(item)
        }

        if let imageData = makeSampleImageData() {
            items.append(
                ClipboardItem(
                    content: .image(imageData, CGSize(width: imageDimension, height: imageDimension)),
                    contentType: .image,
                    sourceAppName: sourceAppName,
                    timestamp: now.addingTimeInterval(-4)
                )
            )
        }

        return items
    }

    // MARK: - Sample payloads

    private static let sourceAppName = "Clipped"
    private static let imageDimension: CGFloat = 96

    private static let plainTextSample = """
    Welcome to Clipped! Copy anything — text, links, or images — \
    and it will show up here for quick reuse.
    """

    private struct SampleRichText {
        let data: Data
        let plain: String
    }

    private static func makeSampleRichText() -> SampleRichText? {
        let heading = "Rich text"
        let body = " preserves formatting like bold, italics, and color."
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
            string: heading,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.systemBlue,
            ]
        ))
        attributed.append(NSAttributedString(
            string: body,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        ))

        guard let data = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else {
            return nil
        }
        return SampleRichText(data: data, plain: heading + body)
    }

    private static func makeSampleImageData() -> Data? {
        let pixelSize = Int(imageDimension)
        // Use a bitmap rep directly so image generation works in headless/test contexts
        // where NSImage.lockFocus() requires a window server.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        let gradient = NSGradient(colors: [NSColor.systemIndigo, NSColor.systemPink])
        gradient?.draw(in: NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18), angle: 135)

        let glyph = NSAttributedString(
            string: "✂︎",
            attributes: [
                .font: NSFont.systemFont(ofSize: 44, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        let glyphSize = glyph.size()
        glyph.draw(at: NSPoint(
            x: rect.midX - glyphSize.width / 2,
            y: rect.midY - glyphSize.height / 2
        ))

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
