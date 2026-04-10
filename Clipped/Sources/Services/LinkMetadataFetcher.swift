import AppKit
import Foundation
import LinkPresentation
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
        guard url.scheme == "http" || url.scheme == "https" else { return LinkMetadata() }

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
        let metadata = await task.value
        inFlight[url] = nil

        if metadata.title != nil || metadata.favicon != nil {
            cacheMetadata(metadata, for: url, originKey: originKey)
        }
        return metadata
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
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
