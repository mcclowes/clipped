import AppKit
import Darwin
import Foundation
@preconcurrency import LinkPresentation
import os
import UniformTypeIdentifiers

struct LinkMetadata {
    var title: String?
    var favicon: Data?
}

protocol LinkMetadataFetching: Sendable {
    func fetchMetadata(for url: URL) async -> LinkMetadata
}

/// Off-main-actor cache + network fetcher. Uses Apple's `LPMetadataProvider` so we don't
/// hand-roll HTML parsing (and inherit whatever entity handling, charset detection, and
/// redirects Apple ship for free). The favicon cache is origin-keyed so different URLs
/// from the same site share a favicon without re-downloading it.
actor LinkMetadataFetcher: LinkMetadataFetching {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "LinkMetadataFetcher")

    static let shared = LinkMetadataFetcher()
    private var titleCache: [URL: String] = [:]
    private var faviconCache: [String: Data] = [:] // Keyed by "scheme://host"
    private var inFlight: [URL: Task<LinkMetadata, Never>] = [:]

    private static let maxCacheSize = 200

    init() {}

    func fetchMetadata(for url: URL) async -> LinkMetadata {
        let signpost = Signposts.linkMetadata.beginInterval("FetchMetadata")
        defer { Signposts.linkMetadata.endInterval("FetchMetadata", signpost) }

        guard Self.isFetchableURL(url) else { return LinkMetadata() }

        let originKey = Self.originKey(for: url)
        if let title = titleCache[url] {
            return LinkMetadata(title: title, favicon: originKey.flatMap { faviconCache[$0] })
        }

        // Deduplicate concurrent requests for the same URL
        if let existing = inFlight[url] {
            return await existing.value
        }

        let task = Task<LinkMetadata, Never> { [weak self] in
            await self?.performFetch(for: url) ?? LinkMetadata()
        }

        inFlight[url] = task
        defer { inFlight[url] = nil }
        let metadata = await task.value

        if metadata.title != nil || metadata.favicon != nil {
            cacheMetadata(metadata, for: url, originKey: originKey)
        }
        return metadata
    }

    /// Lexical pre-check for URLs safe to fetch. Rejects non-http(s), IP-literal hosts in
    /// private/loopback/link-local ranges (parsed to canonical bytes, so alternate encodings
    /// like IPv4-mapped IPv6 can't smuggle a private address past us), and `.local`/unqualified
    /// hostnames. This is only the first gate — non-literal hosts are re-validated against their
    /// *resolved* addresses in `performFetch` before any request is made.
    static func isFetchableURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }

        // IP literals: validate by parsing to canonical bytes. Handles IPv4-mapped IPv6
        // (`::ffff:127.0.0.1`), compressed forms, and NAT64 — not just literal prefixes.
        if let literal = IPLiteral(host) {
            return !literal.isPrivateOrReserved
        }

        if host == "localhost" || host.hasSuffix(".localhost") {
            return false
        }
        if host.hasSuffix(".local") {
            return false
        }
        // Reject unqualified single-label hosts (e.g. "router", "nas"): only public FQDNs allowed.
        if !host.contains(".") {
            return false
        }

        return true
    }

    /// Resolve `host` via DNS and confirm every returned address is publicly routable. Fails
    /// closed on a resolution error or any private/reserved result, which closes the
    /// "public name resolves to an internal IP" SSRF hole and defeats octal/hex IPv4 encodings
    /// that the OS resolver would accept but a lexical filter wouldn't. Runs off the actor so
    /// the blocking `getaddrinfo` call doesn't stall other fetches.
    ///
    /// Note: `LPMetadataProvider` follows HTTP redirects internally and exposes no per-hop hook,
    /// so a public URL that *redirects* to a private address is not covered here. That residual
    /// risk is the reason this validation fails closed and previews are an opt-out setting.
    private static func hostResolvesToPublicAddress(_ host: String) async -> Bool {
        // A validated IP literal needs no DNS lookup.
        if let literal = IPLiteral(host) {
            return !literal.isPrivateOrReserved
        }
        return await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            let status = host.withCString { getaddrinfo($0, nil, &hints, &result) }
            guard status == 0, let head = result else { return false }
            defer { freeaddrinfo(head) }

            var node: UnsafeMutablePointer<addrinfo>? = head
            var sawAddress = false
            while let current = node {
                if let literal = IPLiteral(sockaddr: current.pointee.ai_addr) {
                    sawAddress = true
                    if literal.isPrivateOrReserved {
                        return false
                    }
                }
                node = current.pointee.ai_next
            }
            return sawAddress
        }.value
    }

    // MARK: - Network

    private func performFetch(for url: URL) async -> LinkMetadata {
        guard let host = url.host, await Self.hostResolvesToPublicAddress(host) else {
            Self.logger.debug("Refusing metadata fetch: host resolves to a non-public address")
            return LinkMetadata()
        }
        let provider = LPMetadataProvider()
        provider.timeout = 5
        provider.shouldFetchSubresources = true

        do {
            let lpMetadata = try await provider.startFetchingMetadata(for: url)

            var metadata = LinkMetadata()
            metadata.title = lpMetadata.title.map { String($0.prefix(120)) }

            if let originKey = Self.originKey(for: url), let cached = faviconCache[originKey] {
                metadata.favicon = cached
            } else if let iconProvider = lpMetadata.iconProvider {
                metadata.favicon = await Self.loadImageData(from: iconProvider)
            } else if let imageProvider = lpMetadata.imageProvider {
                metadata.favicon = await Self.loadImageData(from: imageProvider)
            }

            return metadata
        } catch {
            Self.logger.debug("Failed to fetch metadata for \(url.absoluteString): \(error.localizedDescription)")
            return LinkMetadata()
        }
    }

    private func cacheMetadata(_ metadata: LinkMetadata, for url: URL, originKey: String?) {
        if titleCache.count >= Self.maxCacheSize {
            titleCache.removeAll()
        }
        if let title = metadata.title {
            titleCache[url] = title
        }
        if let favicon = metadata.favicon, let originKey {
            if faviconCache.count >= Self.maxCacheSize {
                faviconCache.removeAll()
            }
            faviconCache[originKey] = favicon
        }
    }

    // MARK: - Helpers

    private static func originKey(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)"
    }

    /// Pulls raw bytes off an `NSItemProvider` returned by `LPLinkMetadata`. Downscales nothing —
    /// favicons are already small. Rejects anything larger than 500 KB so a rogue page can't
    /// balloon memory.
    private static func loadImageData(from provider: NSItemProvider) async -> Data? {
        // Prefer PNG, then JPEG, then any image type.
        let preferredTypes: [UTType] = [.png, .jpeg, .image]
        for type in preferredTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await loadData(from: provider, typeIdentifier: type.identifier), data.count < 500_000 {
                return data
            }
        }
        return nil
    }

    private static func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        // NSItemProvider.loadDataRepresentation has no built-in timeout; wrap the continuation
        // with a DispatchQueue-scheduled fallback so a slow CDN can't stall metadata fetches.
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let state = ContinuationState(continuation: continuation)
            let progress = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                state.finish(with: data)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if state.finish(with: nil) {
                    progress.cancel()
                }
            }
        }
    }
}

/// Thread-safe one-shot resume guard for bridging continuation + timeout.
private final class ContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?

    init(continuation: CheckedContinuation<Data?, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(with data: Data?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let c = continuation else { return false }
        continuation = nil
        c.resume(returning: data)
        return true
    }
}

// MARK: - IP literal range helpers

/// A parsed IP address (v4 or v6), canonicalised to raw bytes via `inet_pton` so that every
/// textual encoding of the same address maps to the same reserved-range decision. Prefix/string
/// matching is not safe for this — `::ffff:169.254.169.254` and `0177.0.0.1` are exactly the
/// kinds of representations a string check misses.
struct IPLiteral {
    enum Family { case v4, v6 }
    let family: Family
    let bytes: [UInt8]

    init?(_ host: String) {
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            family = .v4
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            family = .v6
            bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return
        }
        return nil
    }

    /// Build from a resolved `sockaddr` (as returned by `getaddrinfo`).
    init?(sockaddr sa: UnsafeMutablePointer<sockaddr>?) {
        guard let sa else { return nil }
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            family = .v4
            bytes = withUnsafeBytes(of: &addr) { Array($0) }
        case AF_INET6:
            var addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            family = .v6
            bytes = withUnsafeBytes(of: &addr) { Array($0) }
        default:
            return nil
        }
    }

    var isPrivateOrReserved: Bool {
        switch family {
        case .v4: Self.ipv4Reserved(bytes)
        case .v6: Self.ipv6Reserved(bytes)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func ipv4Reserved(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return true }
        let (a, second, third) = (b[0], b[1], b[2])
        if a == 0 {
            return true
        } // 0.0.0.0/8 "this network"
        if a == 10 {
            return true
        } // 10.0.0.0/8 private
        if a == 127 {
            return true
        } // loopback
        if a == 169, second == 254 {
            return true
        } // 169.254/16 link-local
        if a == 172, (16...31).contains(second) {
            return true
        } // 172.16/12 private
        if a == 192, second == 168 {
            return true
        } // 192.168/16 private
        if a == 100, (64...127).contains(second) {
            return true
        } // 100.64/10 CGNAT
        if a == 198, (18...19).contains(second) {
            return true
        } // 198.18/15 benchmarking
        if a == 192, second == 0, third == 0 {
            return true
        } // 192.0.0/24 IETF protocol
        if a >= 224 {
            return true
        } // multicast, reserved, and 255.255.255.255 broadcast
        return false
    }

    static func ipv6Reserved(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return true }
        // IPv4-mapped (::ffff:0:0/96), IPv4-compatible (::/96), and NAT64 (64:ff9b::/96):
        // validate the embedded IPv4 so a mapped private address can't slip through.
        if b.prefix(10).allSatisfy({ $0 == 0 }) {
            if (b[10] == 0xFF && b[11] == 0xFF) || (b[10] == 0 && b[11] == 0) {
                return ipv4Reserved(Array(b[12...]))
            }
        }
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xFF, b[3] == 0x9B, b[4...11].allSatisfy({ $0 == 0 }) {
            return ipv4Reserved(Array(b[12...]))
        }
        if b.allSatisfy({ $0 == 0 }) {
            return true
        } // ::
        if b.prefix(15).allSatisfy({ $0 == 0 }), b[15] == 1 {
            return true
        } // ::1 loopback
        if b[0] == 0xFE, (b[1] & 0xC0) == 0x80 {
            return true
        } // fe80::/10 link-local
        if (b[0] & 0xFE) == 0xFC {
            return true
        } // fc00::/7 unique-local
        if b[0] == 0xFF {
            return true
        } // ff00::/8 multicast
        return false
    }
}
