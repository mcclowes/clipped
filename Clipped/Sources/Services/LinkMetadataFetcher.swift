import Foundation

@MainActor
final class LinkMetadataFetcher {
    static let shared = LinkMetadataFetcher()
    private var cache: [URL: String] = [:]

    private init() {}

    func fetchTitle(for url: URL) async -> String? {
        if let cached = cache[url] { return cached }

        guard url.scheme == "http" || url.scheme == "https" else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                forHTTPHeaderField: "User-Agent"
            )

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let html = String(data: data.prefix(64000), encoding: .utf8)
            else { return nil }

            let title = parseTitle(from: html)
            if let title { cache[url] = title }
            return title
        } catch {
            return nil
        }
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
