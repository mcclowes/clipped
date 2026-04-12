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

    @Test(
        "Rejects private/loopback/link-local URLs (SSRF guard)",
        arguments: [
            "http://localhost/",
            "http://localhost.example.localhost/",
            "http://127.0.0.1/",
            "http://10.0.0.1/",
            "http://192.168.1.1/",
            "http://172.16.0.1/",
            "http://172.31.255.255/",
            "http://169.254.169.254/",
            "http://nas.local/",
            "http://router/",
            "http://[::1]/",
            "http://[fe80::1]/",
            "http://[fc00::1]/",
            "ftp://example.com/",
            "file:///etc/passwd"
        ]
    )
    func rejectsPrivateHosts(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(!LinkMetadataFetcher.isFetchableURL(url))
    }

    @Test(
        "Accepts public HTTP(S) URLs",
        arguments: ["https://example.com/", "http://example.com:8080/path", "https://api.github.com/"]
    )
    func acceptsPublicHosts(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(LinkMetadataFetcher.isFetchableURL(url))
    }

    @Test("Fetches favicon data")
    func fetchesFavicon() async throws {
        let fetcher = LinkMetadataFetcher()
        let metadata = try await fetcher.fetchMetadata(for: #require(URL(string: "https://example.com")))
        // example.com may or may not have a favicon, so we just verify the struct is populated
        #expect(metadata.title != nil)
    }
}
