import AppKit
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

    /// Whitelist-style check for URLs safe to fetch. Rejects non-http(s), IP-literal hosts
    /// in private/loopback/link-local ranges, and `.local`/unqualified hostnames. Prevents
    /// the clipboard manager from probing internal network services on the user's behalf.
    static func isFetchableURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }

        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        if host.hasSuffix(".local") { return false }
        // Reject unqualified single-label hosts (e.g. "router", "nas"): only public FQDNs allowed.
        if !host.contains(".") { return false }

        if let ipv4 = ParsedIPv4(host) {
            if ipv4.isPrivateOrReserved { return false }
        } else if let ipv6 = ParsedIPv6(host) {
            if ipv6.isPrivateOrReserved { return false }
        }

        return true
    }

    // MARK: - Network

    private func performFetch(for url: URL) async -> LinkMetadata {
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

private struct ParsedIPv4 {
    // IPv4 addresses are exactly four octets — a fixed-size tuple is the natural representation.
    // swiftlint:disable:next large_tuple
    let bytes: (UInt8, UInt8, UInt8, UInt8)

    init?(_ string: String) {
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var result: [UInt8] = []
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            result.append(byte)
        }
        bytes = (result[0], result[1], result[2], result[3])
    }

    var isPrivateOrReserved: Bool {
        let (a, b, _, _) = bytes
        if a == 10 { return true } // 10.0.0.0/8
        if a == 127 { return true } // loopback
        if a == 172, (16...31).contains(b) { return true } // 172.16.0.0/12
        if a == 192, b == 168 { return true } // 192.168.0.0/16
        if a == 169, b == 254 { return true } // link-local
        if a == 0 { return true } // "this network"
        if a >= 224 { return true } // multicast + reserved
        if a == 100, (64...127).contains(b) { return true } // CGNAT 100.64.0.0/10
        return false
    }
}

private struct ParsedIPv6 {
    let literal: String

    init?(_ host: String) {
        // URL.host strips brackets; accept raw IPv6 literals with a colon.
        guard host.contains(":") else { return nil }
        literal = host
    }

    var isPrivateOrReserved: Bool {
        let h = literal
        if h == "::1" || h == "::" { return true }
        if h.hasPrefix("fe80") || h.hasPrefix("fc") || h.hasPrefix("fd") { return true }
        if h.hasPrefix("ff") { return true } // multicast
        return false
    }
}
