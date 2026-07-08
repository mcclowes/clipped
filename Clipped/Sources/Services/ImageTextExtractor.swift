import CoreGraphics
import ImageIO
import Vision

/// Extracts human-readable text from raster image data using on-device Vision OCR.
/// Recognition runs off the main thread and is safe to call from any actor.
enum ImageTextExtractor {
    static func extractText(from imageData: Data) async -> String? {
        await Task.detached(priority: .utility) {
            guard let cgImage = Self.cgImage(from: imageData) else { return nil }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }

            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }.value
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
