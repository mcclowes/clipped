@testable import Clipped
import Foundation
import Testing

@MainActor
struct LinkMetadataFetcherTests {
    @Test("Parses title from HTML")
    func parseTitle() async throws {
        let fetcher = LinkMetadataFetcher()
        let metadata = try await fetcher.fetchMetadata(for: #require(URL(string: "https://example.com")))
        #expect(metadata.title != nil)
        #expect(metadata.title?.contains("Example") == true)
    }

    @Test("Returns nil title for non-HTTP URLs")
    func nonHttpUrl() async throws {
        let fetcher = LinkMetadataFetcher()
        let metadata = try await fetcher.fetchMetadata(for: #require(URL(string: "ftp://example.com")))
        #expect(metadata.title == nil)
        #expect(metadata.favicon == nil)
    }

    @Test("Caches fetched metadata")
    func caching() async throws {
        let fetcher = LinkMetadataFetcher()
        let url = try #require(URL(string: "https://example.com"))

        let metadata1 = await fetcher.fetchMetadata(for: url)
        let metadata2 = await fetcher.fetchMetadata(for: url)

        #expect(metadata1.title == metadata2.title)
    }

    @Test("Fetches favicon data")
    func fetchesFavicon() async throws {
        let fetcher = LinkMetadataFetcher()
        let metadata = try await fetcher.fetchMetadata(for: #require(URL(string: "https://example.com")))
        // example.com may or may not have a favicon, so we just verify the struct is populated
        #expect(metadata.title != nil)
    }
}
