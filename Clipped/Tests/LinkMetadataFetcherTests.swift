@testable import Clipped
import Foundation
import Testing

@MainActor
struct LinkMetadataFetcherTests {
    @Test("Parses title from HTML")
    func parseTitle() async throws {
        let fetcher = LinkMetadataFetcher()
        let title = try await fetcher.fetchTitle(for: #require(URL(string: "https://example.com")))
        #expect(title != nil)
        #expect(title?.contains("Example") == true)
    }

    @Test("Returns nil for non-HTTP URLs")
    func nonHttpUrl() async throws {
        let fetcher = LinkMetadataFetcher()
        let title = try await fetcher.fetchTitle(for: #require(URL(string: "ftp://example.com")))
        #expect(title == nil)
    }

    @Test("Caches fetched titles")
    func caching() async throws {
        let fetcher = LinkMetadataFetcher()
        let url = try #require(URL(string: "https://example.com"))

        let title1 = await fetcher.fetchTitle(for: url)
        let title2 = await fetcher.fetchTitle(for: url)

        #expect(title1 == title2)
    }
}
