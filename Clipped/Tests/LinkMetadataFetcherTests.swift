@testable import Clipped
import Darwin
import Foundation
import Testing

@MainActor
struct LinkMetadataFetcherTests {
    @Test("Returns the title supplied by Apple's metadata provider")
    func parseTitle() async throws {
        let provider = MockLinkMetadataProvider(title: "Fixture title")
        let fetcher = LinkMetadataFetcher(provider: provider)
        let metadata = try await fetcher.fetchMetadata(for: #require(URL(string: "https://example.com")))
        #expect(metadata.title == "Fixture title")
        #expect(await provider.requestedURLs.count == 1)
    }

    @Test("Returns nil title for non-HTTP URLs")
    func nonHttpUrl() async throws {
        let provider = MockLinkMetadataProvider()
        let fetcher = LinkMetadataFetcher(provider: provider)
        let metadata = try await fetcher.fetchMetadata(for: #require(URL(string: "ftp://example.com")))
        #expect(metadata.title == nil)
        #expect(metadata.favicon == nil)
        #expect(await provider.validatedHosts.isEmpty)
        #expect(await provider.requestedURLs.isEmpty)
    }

    @Test("Caches fetched metadata")
    func caching() async throws {
        let favicon = TestImageFactory.data(width: 16, height: 16)
        let provider = MockLinkMetadataProvider(favicon: favicon)
        let fetcher = LinkMetadataFetcher(provider: provider)
        let url = try #require(URL(string: "https://example.com"))

        let metadata1 = await fetcher.fetchMetadata(for: url)
        let metadata2 = await fetcher.fetchMetadata(for: url)

        #expect(metadata1.title == "Fixture title")
        #expect(metadata2.title == "Fixture title")
        #expect(metadata1.favicon == favicon)
        #expect(metadata2.favicon == favicon)
        #expect(await provider.requestedURLs == [url])
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
            "http://[fec0::]/",
            "http://[fec0::1]/",
            "https://[FEC0:0:0:0:0:0:0:1]/",
            "http://[fed0:1234::7]:8080/path",
            "http://[feff::1]/",
            "https://[feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]/",
            // Byte-canonical parsing closes these representation-level bypasses:
            "http://[::ffff:127.0.0.1]/", // IPv4-mapped loopback
            "http://[::ffff:169.254.169.254]/", // IPv4-mapped cloud metadata
            "http://[0:0:0:0:0:0:0:1]/", // uncompressed ::1
            "http://[64:ff9b::7f00:1]/", // NAT64 embedding 127.0.0.1
            "http://255.255.255.255/", // broadcast
            "ftp://example.com/",
            "file:///etc/passwd",
        ]
    )
    func rejectsPrivateHosts(_ raw: String) async throws {
        let url = try #require(URL(string: raw))
        #expect(!LinkMetadataFetcher.isFetchableURL(url))
        let provider = MockLinkMetadataProvider()
        let fetcher = LinkMetadataFetcher(provider: provider)
        let metadata = await fetcher.fetchMetadata(for: url)
        #expect(metadata.title == nil)
        #expect(metadata.favicon == nil)
        #expect(await provider.validatedHosts.isEmpty)
        #expect(await provider.requestedURLs.isEmpty)
    }

    @Test(
        "Accepts public HTTP(S) URLs and public IP literals",
        arguments: [
            "https://example.com/",
            "http://example.com:8080/path",
            "https://api.github.com/",
            "http://8.8.8.8/",
            "https://[2606:4700:4700::1111]/", // public Cloudflare IPv6
        ]
    )
    func acceptsPublicHosts(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(LinkMetadataFetcher.isFetchableURL(url))
    }

    @Test("Parses IPv4-mapped IPv6 down to the embedded address")
    func ipv4MappedParsing() {
        #expect(IPLiteral("::ffff:169.254.169.254")?.isPrivateOrReserved == true)
        #expect(IPLiteral("::ffff:8.8.8.8")?.isPrivateOrReserved == false)
        #expect(IPLiteral("127.0.0.1")?.isPrivateOrReserved == true)
        #expect(IPLiteral("8.8.8.8")?.isPrivateOrReserved == false)
    }

    @Test(
        "Rejects deprecated site-local IPv6 literals and resolved addresses",
        arguments: [
            "fec0::",
            "fec0::1",
            "FEC0:0:0:0:0:0:0:1",
            "fed0:1234::7",
            "feff::1",
            "feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
        ]
    )
    func rejectsSiteLocalAddresses(_ address: String) throws {
        let literal = try #require(IPLiteral(address))
        #expect(literal.isPrivateOrReserved)

        var resolved = sockaddr_in6()
        resolved.sin6_family = sa_family_t(AF_INET6)
        let status = address.withCString { inet_pton(AF_INET6, $0, &resolved.sin6_addr) }
        try #require(status == 1)
        let resolvedLiteral = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { IPLiteral(sockaddr: $0) }
        }
        #expect(resolvedLiteral?.isPrivateOrReserved == true)
    }

    @Test(
        "Keeps adjacent IPv6 classification boundaries intact",
        arguments: [
            ("fe7f:ffff:ffff:ffff:ffff:ffff:ffff:ffff", false),
            ("fe80::", true),
            ("febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true),
            ("fec0::", true),
            ("feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true),
            ("ff00::", true),
            ("2606:4700:4700::1111", false),
        ]
    )
    func preservesIPv6Boundaries(_ address: String, reserved: Bool) throws {
        let literal = try #require(IPLiteral(address))
        #expect(literal.isPrivateOrReserved == reserved)
    }

    @Test("Fetches favicon data")
    func fetchesFavicon() async throws {
        let favicon = TestImageFactory.data(width: 16, height: 16)
        let provider = MockLinkMetadataProvider(favicon: favicon)
        let fetcher = LinkMetadataFetcher(provider: provider)
        let metadata = try await fetcher.fetchMetadata(for: #require(URL(string: "https://example.com")))
        #expect(metadata.favicon == favicon)
    }

    @Test("Refuses metadata when the hostname resolves to a non-public address")
    func rejectsNonPublicResolution() async throws {
        let provider = MockLinkMetadataProvider(resolvesPublicly: false)
        let fetcher = LinkMetadataFetcher(provider: provider)
        let metadata = try await fetcher.fetchMetadata(for: #require(URL(string: "https://example.com")))
        #expect(metadata.title == nil)
        #expect(metadata.favicon == nil)
        #expect(await provider.validatedHosts == ["example.com"])
        #expect(await provider.requestedURLs.isEmpty)
    }

    @Test("Limits titles to 120 characters", arguments: [119, 120, 121])
    func limitsTitleLength(_ length: Int) async throws {
        let title = String(repeating: "🧑🏽‍💻", count: length)
        let provider = MockLinkMetadataProvider(title: title)
        let fetcher = LinkMetadataFetcher(provider: provider)
        let metadata = try await fetcher.fetchMetadata(for: #require(URL(string: "https://example.com")))
        #expect(metadata.title?.count == min(length, 120))
    }

    @Test("Uses the preview image when no favicon is supplied")
    func fallsBackToPreviewImage() async throws {
        let image = TestImageFactory.data(width: 32, height: 32)
        let provider = MockLinkMetadataProvider(image: image)
        let fetcher = LinkMetadataFetcher(provider: provider)
        let metadata = try await fetcher.fetchMetadata(for: #require(URL(string: "https://example.com")))
        #expect(metadata.favicon == image)
    }

    @Test("Prefers the favicon over the preview image")
    func prefersFavicon() async throws {
        let favicon = TestImageFactory.data(width: 16, height: 16)
        let image = TestImageFactory.data(width: 32, height: 32)
        let provider = MockLinkMetadataProvider(favicon: favicon, image: image)
        let fetcher = LinkMetadataFetcher(provider: provider)
        let metadata = try await fetcher.fetchMetadata(for: #require(URL(string: "https://example.com")))
        #expect(metadata.favicon == favicon)
    }

    @Test("Rejects favicon data at the 500 KB limit", arguments: [499_999, 500_000])
    func limitsFaviconSize(_ size: Int) async throws {
        var favicon = TestImageFactory.data(width: 16, height: 16)
        favicon.append(Data(count: size - favicon.count))
        let provider = MockLinkMetadataProvider(favicon: favicon)
        let fetcher = LinkMetadataFetcher(provider: provider)
        let metadata = try await fetcher.fetchMetadata(for: #require(URL(string: "https://example.com")))
        #expect(metadata.favicon == (size < 500_000 ? favicon : nil))
    }
}
