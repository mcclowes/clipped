import Foundation
import os

@MainActor
protocol LinkMetadataFetching: AnyObject {
    func fetchTitle(for url: URL) async -> String?
}

@MainActor
final class LinkMetadataFetcher: LinkMetadataFetching {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "LinkMetadataFetcher")

    static let shared = LinkMetadataFetcher()
    private var cache: [URL: String] = [:]
    private var inFlight: [URL: Task<String?, Never>] = [:]

    private static let maxCacheSize = 200

    init() {}

    func fetchTitle(for url: URL) async -> String? {
        if let cached = cache[url] { return cached }

        guard url.scheme == "http" || url.scheme == "https" else { return nil }

        // Deduplicate concurrent requests for the same URL
        if let existing = inFlight[url] {
            return await existing.value
        }

        let task = Task<String?, Never> {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                request.httpShouldHandleCookies = false

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let html = String(data: data.prefix(64000), encoding: .utf8)
                else { return nil }

                return parseTitle(from: html)
            } catch {
                Self.logger.debug("Failed to fetch title for \(url.absoluteString): \(error.localizedDescription)")
                return nil
            }
        }

        inFlight[url] = task
        let title = await task.value
        inFlight[url] = nil

        if let title {
            if cache.count >= Self.maxCacheSize {
                cache.removeAll()
            }
            cache[url] = title
        }
        return title
    }

    private func parseTitle(from html: String) -> String? {
        // Simple regex-based title extraction — no dependencies needed
        guard let openRange = html.range(of: "<title", options: .caseInsensitive),
              let closeStart = html.range(of: ">", range: openRange.upperBound..<html.endIndex),
              let closeEnd = html.range(
                  of: "</title>",
                  options: .caseInsensitive,
                  range: closeStart.upperBound..<html.endIndex
              )
        else { return nil }

        let title = String(html[closeStart.upperBound..<closeEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")

        return title.isEmpty ? nil : String(title.prefix(120))
    }
}
