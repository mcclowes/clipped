import Foundation
import os

struct LinkMetadata {
    var title: String?
    var favicon: Data?
}

protocol LinkMetadataFetching: Sendable {
    func fetchMetadata(for url: URL) async -> LinkMetadata
}

/// Off-main-actor cache + network fetcher. Implemented as an `actor` so callers on the
/// main actor don't block on the cache lookup or the URLSession response.
actor LinkMetadataFetcher: LinkMetadataFetching {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "LinkMetadataFetcher")

    static let shared = LinkMetadataFetcher()
    private var cache: [URL: LinkMetadata] = [:]
    private var inFlight: [URL: Task<LinkMetadata, Never>] = [:]

    private static let maxCacheSize = 200

    init() {}

    func fetchMetadata(for url: URL) async -> LinkMetadata {
        if let cached = cache[url] { return cached }

        guard url.scheme == "http" || url.scheme == "https" else { return LinkMetadata() }

        // Deduplicate concurrent requests for the same URL
        if let existing = inFlight[url] {
            return await existing.value
        }

        let task = Task<LinkMetadata, Never> {
            var metadata = LinkMetadata()

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                request.httpShouldHandleCookies = false

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let html = String(data: data.prefix(64000), encoding: .utf8)
                else { return metadata }

                metadata.title = parseTitle(from: html)

                let faviconURL = parseFaviconURL(from: html, pageURL: url) ?? Self.faviconFallbackURL(for: url)
                if let faviconURL {
                    metadata.favicon = await Self.fetchFaviconData(from: faviconURL)
                }
            } catch {
                Self.logger.debug("Failed to fetch metadata for \(url.absoluteString): \(error.localizedDescription)")
            }

            return metadata
        }

        inFlight[url] = task
        let metadata = await task.value
        inFlight[url] = nil

        if metadata.title != nil || metadata.favicon != nil {
            if cache.count >= Self.maxCacheSize {
                cache.removeAll()
            }
            cache[url] = metadata
        }
        return metadata
    }

    // MARK: - Title parsing

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

    // MARK: - Favicon parsing

    private func parseFaviconURL(from html: String, pageURL: URL) -> URL? {
        var searchFrom = html.startIndex

        while let linkStart = html.range(of: "<link ", options: .caseInsensitive, range: searchFrom..<html.endIndex) {
            guard let tagEnd = html.range(of: ">", range: linkStart.upperBound..<html.endIndex) else { break }

            let tag = String(html[linkStart.lowerBound..<tagEnd.upperBound])
            let tagLower = tag.lowercased()
            searchFrom = tagEnd.upperBound

            // Must have rel containing "icon" but skip apple-touch-icon and mask-icon
            guard tagLower.contains("icon"),
                  tagLower.contains("rel="),
                  !tagLower.contains("apple-touch-icon"),
                  !tagLower.contains("mask-icon")
            else { continue }

            guard let hrefStart = tag.range(of: "href=", options: .caseInsensitive) else { continue }
            let afterHref = tag[hrefStart.upperBound...]
            guard let quoteChar = afterHref.first, quoteChar == "\"" || quoteChar == "'" else { continue }
            let valueStart = afterHref.index(after: afterHref.startIndex)
            guard let valueEnd = afterHref[valueStart...].firstIndex(of: quoteChar) else { continue }
            let href = String(afterHref[valueStart..<valueEnd])

            guard !href.isEmpty else { continue }

            return Self.resolveURL(href, against: pageURL)
        }

        return nil
    }

    private static func resolveURL(_ href: String, against baseURL: URL) -> URL? {
        if href.hasPrefix("http://") || href.hasPrefix("https://") {
            URL(string: href)
        } else if href.hasPrefix("//") {
            URL(string: "\(baseURL.scheme ?? "https"):\(href)")
        } else {
            URL(string: href, relativeTo: baseURL)?.absoluteURL
        }
    }

    private static func faviconFallbackURL(for url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }

    private static func fetchFaviconData(from url: URL) async -> Data? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.httpShouldHandleCookies = false

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  !data.isEmpty,
                  data.count < 500_000
            else { return nil }

            return data
        } catch {
            return nil
        }
    }
}
