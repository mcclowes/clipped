import AppKit
import CryptoKit
import Foundation
import os

protocol HistoryStoring: Sendable {
    func save(entries: [StoredEntry]) async
    func load() async -> [StoredEntry]
    func clear() async
    func lastLoadError() async -> HistoryLoadError?
    func startFresh() async
}

enum HistoryLoadError: Error, Equatable {
    /// The Keychain key could not be read (e.g. Keychain reset, restored from a backup
    /// on a different Mac). Encrypted history remains on disk — the user is prompted
    /// to either unlock the Keychain and retry, or discard the old data and start fresh.
    case keyUnavailable
    /// `history.enc` exists on disk but cannot be decrypted with the current key.
    case decryptionFailed
    /// `history.enc` exists but is shorter than the crypto overhead, so we can't even
    /// begin to decrypt it. Treated the same as `decryptionFailed` by the UI.
    case corrupted
}

/// Persists clipboard history to disk, encrypted at rest with `ChaChaPoly`.
///
/// Layout under `~/Library/Application Support/Clipped/`:
///
/// - `history.enc`           — encrypted JSON of `[StoredEntry]` (without image bytes)
/// - `images/<uuid>.enc`     — per-image encrypted blob (raster clipboard payloads)
///
/// The symmetric key is provisioned on first run and stored in the login Keychain via
/// `KeychainKeyStore`, with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The key
/// never touches disk.
///
/// On first launch after upgrade, legacy plaintext `history.json` and `images/*.{png,tiff}`
/// files are detected and re-encrypted in place, then the plaintext is deleted. Disk I/O
/// is isolated to this actor so callers on the main actor never block the UI.
actor HistoryStore: HistoryStoring {
    static let shared = HistoryStore()

    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "HistoryStore")

    private let encryptedFileURL: URL
    private let legacyPlaintextFileURL: URL
    private let imagesDir: URL
    private let keyStore: any KeychainKeyStoring

    private var cryptoCache: HistoryCrypto?
    private var loadError: HistoryLoadError?

    init(keyStore: any KeychainKeyStoring = KeychainKeyStore()) {
        self.keyStore = keyStore

        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            fatalError("Application Support directory not found")
        }
        let appDir = appSupport.appendingPathComponent("Clipped", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        encryptedFileURL = appDir.appendingPathComponent("history.enc")
        legacyPlaintextFileURL = appDir.appendingPathComponent("history.json")
        imagesDir = appDir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    func lastLoadError() -> HistoryLoadError? {
        loadError
    }

    func save(entries: [StoredEntry]) async {
        guard let crypto = try? resolveCrypto() else {
            Self.logger.error("Refusing to save: encryption key unavailable")
            loadError = .keyUnavailable
            return
        }

        // Write image payloads to their own encrypted files and build wire entries with
        // imageData stripped so the JSON stays small.
        var wireEntries: [StoredEntry] = []
        wireEntries.reserveCapacity(entries.count)
        var liveImageIDs: Set<UUID> = []

        for entry in entries {
            if let data = entry.imageData {
                writeEncryptedImageFile(data: data, id: entry.id, crypto: crypto)
                liveImageIDs.insert(entry.id)
            }
            wireEntries.append(entry.strippingImageData())
        }

        deleteOrphanedImageFiles(keeping: liveImageIDs)

        do {
            let plaintext = try JSONEncoder().encode(wireEntries)
            let ciphertext = try crypto.encrypt(plaintext)
            try writeAtomically(data: ciphertext, to: encryptedFileURL)

            // Upgrade path: a legacy plaintext file may still be sitting next to us from
            // a previous install. Once we've confirmed the encrypted write succeeded, the
            // plaintext is redundant — remove it.
            if FileManager.default.fileExists(atPath: legacyPlaintextFileURL.path) {
                try? FileManager.default.removeItem(at: legacyPlaintextFileURL)
            }
        } catch {
            Self.logger.error("Failed to save encrypted history: \(error.localizedDescription)")
        }
    }

    func load() async -> [StoredEntry] {
        let crypto: HistoryCrypto
        do {
            crypto = try resolveCrypto()
        } catch {
            Self.logger.error("Encryption key unavailable: \(error.localizedDescription)")
            // If there's nothing on disk yet we can't actually lose anything — fall back
            // to an empty history and try to provision a fresh key the next time save()
            // is called. Only flag keyUnavailable when encrypted data genuinely exists.
            if FileManager.default.fileExists(atPath: encryptedFileURL.path) {
                loadError = .keyUnavailable
            }
            return []
        }

        // First-launch-after-upgrade migration: legacy plaintext present, encrypted file
        // absent. Re-encrypt the JSON in place, migrate each image file, then delete the
        // plaintext originals.
        if !FileManager.default.fileExists(atPath: encryptedFileURL.path),
           FileManager.default.fileExists(atPath: legacyPlaintextFileURL.path)
        {
            migrateLegacyPlaintext(crypto: crypto)
        }

        guard FileManager.default.fileExists(atPath: encryptedFileURL.path) else {
            loadError = nil
            return []
        }

        let ciphertext: Data
        do {
            ciphertext = try Data(contentsOf: encryptedFileURL)
        } catch {
            Self.logger.error("Failed to read encrypted history file: \(error.localizedDescription)")
            loadError = .corrupted
            return []
        }

        let plaintext: Data
        do {
            plaintext = try crypto.decrypt(ciphertext)
        } catch HistoryCryptoError.corrupted {
            Self.logger.error("Encrypted history file is shorter than crypto overhead")
            loadError = .corrupted
            return []
        } catch {
            Self.logger.error("Failed to decrypt history: \(error.localizedDescription)")
            loadError = .decryptionFailed
            return []
        }

        let decoded: [StoredEntry]
        do {
            decoded = try JSONDecoder().decode([StoredEntry].self, from: plaintext)
        } catch {
            Self.logger
                .error("History plaintext corrupted, backing up and starting fresh: \(error.localizedDescription)")
            let backupURL = encryptedFileURL.deletingLastPathComponent()
                .appendingPathComponent("history.corrupted.enc")
            try? FileManager.default.moveItem(at: encryptedFileURL, to: backupURL)
            loadError = nil
            return []
        }

        loadError = nil

        // Hydrate image payloads from the side files. If a legacy entry still has
        // imageData embedded, pass it through untouched — the next save() will migrate
        // it. SVG entries ride on contentType "Image" but keep their bytes inline via
        // `svgData`, so skip the sidecar lookup for those.
        return decoded.map { entry in
            guard entry.contentType == "Image", entry.imageData == nil, entry.svgData == nil
            else { return entry }
            guard let payload = loadEncryptedImageFile(for: entry.id, crypto: crypto)
            else { return entry }
            return entry.withImageData(payload)
        }
    }

    func clear() async {
        try? FileManager.default.removeItem(at: encryptedFileURL)
        try? FileManager.default.removeItem(at: legacyPlaintextFileURL)
        try? FileManager.default.removeItem(at: imagesDir)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        loadError = nil
    }

    /// Recovery path for a missing or unreadable Keychain key. Drops the old encrypted
    /// data (which is unreadable anyway) and provisions a brand new key for future writes.
    func startFresh() async {
        try? FileManager.default.removeItem(at: encryptedFileURL)
        try? FileManager.default.removeItem(at: imagesDir)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try? keyStore.deleteKey()
        cryptoCache = nil
        loadError = nil
    }

    // MARK: - Key / crypto resolution

    private func resolveCrypto() throws -> HistoryCrypto {
        if let cached = cryptoCache {
            return cached
        }
        let key = try keyStore.loadOrCreateKey()
        let crypto = HistoryCrypto(key: key)
        cryptoCache = crypto
        return crypto
    }

    // MARK: - Atomic writes

    private func writeAtomically(data: Data, to url: URL) throws {
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp")
        FileManager.default.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        _ = try FileManager.default.replaceItemAt(
            url,
            withItemAt: tempURL,
            options: .usingNewMetadataOnly
        )
    }

    // MARK: - Image files

    private func encryptedImageURL(for id: UUID) -> URL {
        imagesDir.appendingPathComponent("\(id.uuidString).enc")
    }

    private func legacyImageURLs(for id: UUID) -> [URL] {
        ["png", "tiff"].map { ext in
            imagesDir.appendingPathComponent("\(id.uuidString).\(ext)")
        }
    }

    private func loadEncryptedImageFile(for id: UUID, crypto: HistoryCrypto) -> Data? {
        let url = encryptedImageURL(for: id)
        guard let ciphertext = try? Data(contentsOf: url) else { return nil }
        return try? crypto.decrypt(ciphertext)
    }

    private func writeEncryptedImageFile(data: Data, id: UUID, crypto: HistoryCrypto) {
        do {
            let ciphertext = try crypto.encrypt(data)
            try writeAtomically(data: ciphertext, to: encryptedImageURL(for: id))
        } catch {
            Self.logger.error("Failed to write encrypted image \(id): \(error.localizedDescription)")
        }
    }

    /// Remove any encrypted image files on disk whose UUID is no longer in the live set.
    /// Legacy plaintext images are swept up at the same time — once migration has run
    /// there's no reason to leave them around.
    private func deleteOrphanedImageFiles(keeping liveIDs: Set<UUID>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: imagesDir,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in entries {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: stem) else { continue }
            let ext = url.pathExtension.lowercased()
            if ext == "png" || ext == "tiff" {
                // Legacy plaintext image — always remove, it's been migrated by now.
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if !liveIDs.contains(id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Legacy migration

    private func migrateLegacyPlaintext(crypto: HistoryCrypto) {
        Self.logger.info("Migrating legacy plaintext history to encrypted storage")
        do {
            let plaintext = try Data(contentsOf: legacyPlaintextFileURL)
            // Sanity-check that it actually decodes before we trust it enough to delete
            // the plaintext. If decoding fails we leave the plaintext alone so the user
            // can recover it manually.
            _ = try JSONDecoder().decode([StoredEntry].self, from: plaintext)
            let ciphertext = try crypto.encrypt(plaintext)
            try writeAtomically(data: ciphertext, to: encryptedFileURL)
        } catch {
            Self.logger.error("Failed to migrate legacy history.json: \(error.localizedDescription)")
            return
        }

        // Migrate any plaintext image side files.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: imagesDir,
            includingPropertiesForKeys: nil
        ) {
            for url in entries {
                let ext = url.pathExtension.lowercased()
                guard ext == "png" || ext == "tiff" else { continue }
                let stem = url.deletingPathExtension().lastPathComponent
                guard let id = UUID(uuidString: stem) else { continue }
                guard let data = try? Data(contentsOf: url) else { continue }
                writeEncryptedImageFile(data: data, id: id, crypto: crypto)
                try? FileManager.default.removeItem(at: url)
            }
        }

        // Finally, drop the plaintext history file now that the encrypted copy is safe.
        try? FileManager.default.removeItem(at: legacyPlaintextFileURL)
    }
}

// MARK: - Codable storage model

/// Serialization-friendly snapshot of a ClipboardItem. Conversions that touch
/// ClipboardItem live in a @MainActor extension so this struct itself is Sendable
/// by default (all stored properties are value types).
struct StoredEntry: Codable {
    let id: UUID
    let contentType: String
    let textContent: String?
    let rtfData: Data?
    let urlString: String?
    let imageData: Data?
    let imageWidth: Double?
    let imageHeight: Double?
    /// Raw SVG markup bytes. Stored inline in `history.enc` since SVG is text —
    /// the external image-file path is reserved for raster payloads.
    let svgData: Data?
    let sourceAppName: String?
    let sourceAppBundleID: String?
    let timestamp: Date
    let isPinned: Bool
    let isDeveloperContent: Bool?
    /// Nullable for backward compat with history files written before secret detection existed.
    let containsSecret: Bool?
    let linkTitle: String?
    let linkFavicon: Data?
    let mutationsApplied: [String]?
    /// Nullable for backward compat with v1 history files that predate content categories.
    let detectedCategories: [String]?
    /// Opaque pasteboard payloads captured from apps with custom UTIs (Logic Pro, etc.)
    /// so paste into the source app still works after history reload. Nullable for
    /// backward compat with history files written before this existed.
    let customPasteboardTypes: [String: Data]?

    /// Copy of this entry with `imageData` cleared, used when writing the JSON envelope
    /// so a 4 MB screenshot doesn't round-trip as base64 inside the history file.
    func strippingImageData() -> StoredEntry {
        StoredEntry(
            id: id,
            contentType: contentType,
            textContent: textContent,
            rtfData: rtfData,
            urlString: urlString,
            imageData: nil,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            svgData: svgData,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID,
            timestamp: timestamp,
            isPinned: isPinned,
            isDeveloperContent: isDeveloperContent,
            containsSecret: containsSecret,
            linkTitle: linkTitle,
            linkFavicon: linkFavicon,
            mutationsApplied: mutationsApplied,
            detectedCategories: detectedCategories,
            customPasteboardTypes: nil
        )
    }

    /// Copy of this entry with `imageData` hydrated from disk during load.
    func withImageData(_ data: Data) -> StoredEntry {
        StoredEntry(
            id: id,
            contentType: contentType,
            textContent: textContent,
            rtfData: rtfData,
            urlString: urlString,
            imageData: data,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            svgData: svgData,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID,
            timestamp: timestamp,
            isPinned: isPinned,
            isDeveloperContent: isDeveloperContent,
            containsSecret: containsSecret,
            linkTitle: linkTitle,
            linkFavicon: linkFavicon,
            mutationsApplied: mutationsApplied,
            detectedCategories: detectedCategories,
            customPasteboardTypes: customPasteboardTypes
        )
    }
}

@MainActor
extension StoredEntry {
    init(item: ClipboardItem) {
        let textContent: String?
        let rtfData: Data?
        let urlString: String?
        let imageData: Data?
        let svgData: Data?
        let imageWidth: Double?
        let imageHeight: Double?

        switch item.content {
        case let .text(string):
            textContent = string
            rtfData = nil
            urlString = nil
            imageData = nil
            svgData = nil
            imageWidth = nil
            imageHeight = nil
        case let .richText(data, plain):
            textContent = plain
            rtfData = data
            urlString = nil
            imageData = nil
            svgData = nil
            imageWidth = nil
            imageHeight = nil
        case let .url(url):
            textContent = nil
            rtfData = nil
            urlString = url.absoluteString
            imageData = nil
            svgData = nil
            imageWidth = nil
            imageHeight = nil
        case let .image(data, size):
            textContent = nil
            rtfData = nil
            urlString = nil
            imageData = data
            svgData = nil
            imageWidth = size.width
            imageHeight = size.height
        case let .svg(data, size):
            textContent = nil
            rtfData = nil
            urlString = nil
            imageData = nil
            svgData = data
            imageWidth = size.width
            imageHeight = size.height
        }

        self.init(
            id: item.id,
            contentType: item.contentType.rawValue,
            textContent: textContent,
            rtfData: rtfData,
            urlString: urlString,
            imageData: imageData,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            svgData: svgData,
            sourceAppName: item.sourceAppName,
            sourceAppBundleID: item.sourceAppBundleID,
            timestamp: item.timestamp,
            isPinned: item.isPinned,
            isDeveloperContent: item.isDeveloperContent,
            containsSecret: item.containsSecret ? true : nil,
            linkTitle: item.linkTitle,
            linkFavicon: item.linkFavicon,
            mutationsApplied: item.mutationsApplied.isEmpty ? nil : item.mutationsApplied,
            detectedCategories: item.detectedCategories.isEmpty
                ? nil
                : item.detectedCategories.map(\.rawValue).sorted(),
            customPasteboardTypes: item.customPasteboardTypes
        )
    }

    func toClipboardItem() -> ClipboardItem? {
        let resolvedType = contentType == "Code" ? "Text" : contentType
        guard let type = ContentType(rawValue: resolvedType),
              let content = decodeContent(for: type) else { return nil }

        let decodedCategories: Set<ContentCategory> = Set(
            (detectedCategories ?? []).compactMap(ContentCategory.init(rawValue:))
        )
        let item = ClipboardItem(
            id: id,
            content: content,
            contentType: type,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID,
            timestamp: timestamp,
            isPinned: isPinned,
            containsSecret: containsSecret ?? false,
            isDeveloperContent: isDeveloperContent ?? false,
            detectedCategories: decodedCategories
        )
        item.linkTitle = linkTitle
        item.linkFavicon = linkFavicon
        item.mutationsApplied = mutationsApplied ?? []
        item.customPasteboardTypes = customPasteboardTypes
        return item
    }

    private func decodeContent(for type: ContentType) -> ClipboardContent? {
        switch type {
        case .plainText:
            return textContent.map(ClipboardContent.text)
        case .richText:
            if let rtf = rtfData, let plain = textContent {
                return .richText(rtf, plain)
            }
            return textContent.map(ClipboardContent.text)
        case .url:
            guard let str = urlString, let url = URL(string: str) else { return nil }
            return .url(url)
        case .image:
            let size = CGSize(width: imageWidth ?? 0, height: imageHeight ?? 0)
            // SVG entries ride on ContentType.image but carry their bytes in `svgData`.
            if let data = svgData {
                return .svg(data, size)
            }
            return imageData.map { .image($0, size) }
        }
    }
}
