import AppKit
import Carbon
@testable import Clipped
import CryptoKit
import Darwin
import Foundation
import ImageIO
@preconcurrency import class LinkPresentation.LPLinkMetadata
import LocalAuthentication
import ServiceManagement
import UniformTypeIdentifiers

final class MockUnavailableAuthenticationContext: LAContext {
    private let lock = NSLock()
    private var evaluationCount = 0

    var evaluations: Int {
        lock.lock()
        defer { lock.unlock() }
        return evaluationCount
    }

    override func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
        false
    }

    override func evaluatePolicy(
        _ policy: LAPolicy,
        localizedReason: String,
        reply: @escaping @Sendable (Bool, Error?) -> Void
    ) {
        lock.lock()
        evaluationCount += 1
        lock.unlock()
        reply(false, nil)
    }
}

@MainActor
final class MockPasteBackApplication: PasteBackApplication {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    var isTerminated = false
    var activationSucceeds = true
    var onActivate: (() -> Void)?
    private(set) var activationCount = 0

    init(bundleIdentifier: String = "com.example.editor", processIdentifier: pid_t = 123) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }

    func activateForPaste() -> Bool {
        activationCount += 1
        onActivate?()
        return activationSucceeds
    }
}

@MainActor
final class MockPasteBackEnvironment: PasteBackEnvironment {
    var frontmostApplication: (any PasteBackApplication)?
    var isSecureInputEnabled = false
    var onWait: (() throws -> Void)?
    private(set) var waitCount = 0
    private(set) var pastedProcessIDs: [pid_t?] = []

    func waitForActivation() async throws {
        waitCount += 1
        try onWait?()
    }

    func postPaste() {
        pastedProcessIDs.append(frontmostApplication?.processIdentifier)
    }
}

/// Test key store; every access to its symmetric key is protected by the lock.
final class InMemoryKeyStore: KeychainKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?

    init(initialKey: SymmetricKey? = nil) {
        key = initialKey
    }

    func loadKey() throws -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    func generateAndStoreKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        let newKey = SymmetricKey(size: .bits256)
        key = newKey
        return newKey
    }

    func deleteKey() throws {
        lock.lock()
        defer { lock.unlock() }
        key = nil
    }
}

@MainActor
final class MockKeyEventMonitor {
    private let token = NSObject()
    private(set) var additions = 0
    private(set) var removals = 0
    private(set) var handler: (@MainActor (NSEvent) -> NSEvent?)?

    var system: KeyRecorderMonitor.MonitorSystem {
        .init(
            add: { handler in
                self.additions += 1
                self.handler = handler
                return self.token
            },
            remove: { monitor in
                precondition((monitor as AnyObject) === self.token)
                self.removals += 1
            }
        )
    }
}

actor MockLinkMetadataProvider: LinkMetadataProviding {
    private(set) var requestedURLs: [URL] = []
    private(set) var validatedHosts: [String] = []
    let title: String?
    let favicon: Data?
    let image: Data?
    let resolvesPublicly: Bool

    init(
        title: String? = "Fixture title",
        favicon: Data? = nil,
        image: Data? = nil,
        resolvesPublicly: Bool = true
    ) {
        self.title = title
        self.favicon = favicon
        self.image = image
        self.resolvesPublicly = resolvesPublicly
    }

    func hostResolvesToPublicAddress(_ host: String) -> Bool {
        validatedHosts.append(host)
        return resolvesPublicly
    }

    /// Nonisolated so the fresh `LPLinkMetadata` leaves in its own region: Xcode 16's checker
    /// rejects a `sending` result that was assembled inside an actor-isolated method.
    nonisolated func fetchMetadata(for url: URL) async -> sending LPLinkMetadata {
        await recordRequest(url)
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.iconProvider = favicon.map(Self.imageProvider)
        metadata.imageProvider = image.map(Self.imageProvider)
        return metadata
    }

    private func recordRequest(_ url: URL) {
        requestedURLs.append(url)
    }

    private static func imageProvider(_ data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

/// Encodes a solid-colour test image of the given pixel size to `format`. Centralised
/// here so the force-unwraps (all on compile-time-safe ImageIO calls) live in one place.
@MainActor
enum TestImageFactory {
    // swiftlint:disable force_unwrapping
    static func data(width: Int, height: Int, format: RasterImageFormat = .png) -> Data {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!

        let buffer = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            format.utType.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return buffer as Data
    }

    /// A solid-colour image wrapped in a `ClipboardItem` for export/transform tests.
    static func imageItem(width: Int = 40, height: Int = 30) -> ClipboardItem {
        ClipboardItem(
            content: .image(data(width: width, height: height), CGSize(width: width, height: height)),
            contentType: .image
        )
    }

    // swiftlint:enable force_unwrapping
}

enum ScreenshotMetadataFixture {
    enum InvalidValue: CaseIterable, Sendable {
        case falseFlag, number, text, malformed, oversized

        func data() throws -> Data {
            let value: Any
            switch self {
            case .falseFlag: value = false
            case .number: value = 1
            case .text: value = "true"
            case .malformed: return Data("not a property list".utf8)
            case .oversized: return Data(repeating: 0, count: 5000)
            }
            return try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        }
    }

    static func mark(_ url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        try write(data, to: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return data.withUnsafeBytes { buffer in
                setxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", buffer.baseAddress, buffer.count, 0, 0)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
    }
}

/// In-memory pasteboard that records writes and can simulate external writes from other apps.
/// Matches `NSPasteboard`'s surface via `PasteboardProtocol` so both `PasteboardMonitor`
/// and `ClipboardManager` write paths can be unit-tested without touching the real clipboard.
@MainActor
final class MockPasteboard: PasteboardProtocol {
    private(set) var changeCount: Int = 0
    private var availableTypes: [NSPasteboard.PasteboardType] = []
    private var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
    private var stringByType: [NSPasteboard.PasteboardType: String] = [:]

    var types: [NSPasteboard.PasteboardType]? {
        availableTypes.isEmpty ? nil : availableTypes
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        dataByType[type]
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        stringByType[type]
    }

    @discardableResult
    func clearContents() -> Int {
        availableTypes.removeAll()
        dataByType.removeAll()
        stringByType.removeAll()
        changeCount += 1
        return changeCount
    }

    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        stringByType[type] = string
        if !availableTypes.contains(type) {
            availableTypes.append(type)
        }
        return true
    }

    @discardableResult
    func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool {
        guard let data else { return false }
        dataByType[type] = data
        if !availableTypes.contains(type) {
            availableTypes.append(type)
        }
        return true
    }

    /// Simulate an external app writing to the pasteboard: clears prior state, installs the
    /// given types/values, and bumps `changeCount` so the next `PasteboardMonitor.check()`
    /// treats it as fresh content.
    func stageExternalWrite(
        types: [NSPasteboard.PasteboardType],
        strings: [NSPasteboard.PasteboardType: String] = [:],
        data: [NSPasteboard.PasteboardType: Data] = [:]
    ) {
        availableTypes = types
        stringByType = strings
        dataByType = data
        changeCount += 1
    }
}

/// Sendable test double for HistoryStoring. State is protected by an internal actor
/// so the mock can be used from async tests and matches the production actor shape.
final class MockHistoryStore: HistoryStoring, @unchecked Sendable {
    /// Exposed for assertions; tests run serially on the main actor so unchecked is fine.
    private let state: MockState

    init() {
        state = MockState()
    }

    var savedEntries: [StoredEntry] {
        get async { await state.savedEntries }
    }

    var saveCallCount: Int {
        get async { await state.saveCallCount }
    }

    var clearCallCount: Int {
        get async { await state.clearCallCount }
    }

    func setLoadResult(_ entries: [StoredEntry]) async {
        await state.setLoadResult(entries)
    }

    func save(entries: [StoredEntry]) async {
        await state.save(entries: entries)
    }

    func load() async -> [StoredEntry] {
        await state.load()
    }

    func clear() async {
        await state.clear()
    }

    func lastLoadError() async -> HistoryLoadError? {
        await state.lastLoadError
    }

    func startFresh() async {
        await state.startFresh()
    }

    func retryLoad() async -> [StoredEntry] {
        await state.load()
    }

    func setLastLoadError(_ error: HistoryLoadError?) async {
        await state.setLastLoadError(error)
    }

    private actor MockState {
        var savedEntries: [StoredEntry] = []
        var saveCallCount = 0
        var clearCallCount = 0
        var loadResult: [StoredEntry] = []
        var lastLoadError: HistoryLoadError?
        var startFreshCallCount = 0

        func setLoadResult(_ entries: [StoredEntry]) {
            loadResult = entries
        }

        func setLastLoadError(_ error: HistoryLoadError?) {
            lastLoadError = error
        }

        func save(entries: [StoredEntry]) {
            savedEntries = entries
            saveCallCount += 1
        }

        func load() -> [StoredEntry] {
            loadResult
        }

        func clear() {
            clearCallCount += 1
            // Mirror the real store: clearing erases what a later load would return.
            loadResult = []
            savedEntries = []
        }

        func startFresh() {
            startFreshCallCount += 1
            lastLoadError = nil
        }
    }
}

@MainActor
final class MockSettingsManager: SettingsManaging, MutationRulesProviding {
    var persistAcrossReboots = false
    var maxHistorySize = 10
    var historyRetention: HistoryRetention = .never
    var secureMode = true
    var secureTimeout = SettingsManager.defaultSecureTimeout
    var secretHandling: SecretHandling = .maskOnly
    var playSoundOnCopy = false
    var captureScreenshots = false
    var copyScreenshotsToClipboard = false
    var fetchLinkPreviews = true
    var hideFromScreenSharing = true
    var launchAtLogin = false
    var hotkeyKeyCode: UInt32 = 8
    var hotkeyModifiers: UInt32 = .init(optionKey)
    var historyWindowHotkeyKeyCode: UInt32 = 8
    var historyWindowHotkeyModifiers: UInt32 = .init(optionKey | shiftKey)
    var mutationRules: [String: Bool] = [:]
    var mutationAppOverrides: [String: Bool] = [:]
    var disabledFilterIDs: Set<String> = []

    // MARK: - MutationRulesProviding

    func isEnabled(_ mutationID: MutationID, for contentType: ContentType) -> Bool {
        let key = "\(mutationID.rawValue):\(contentType.rawValue)"
        return mutationRules[key] ??
            (mutationID.defaultContentTypes.contains(contentType) && mutationID.enabledByDefault)
    }

    func isOverridden(_ mutationID: MutationID, for bundleID: String) -> Bool? {
        let key = "\(mutationID.rawValue):\(bundleID)"
        return mutationAppOverrides[key]
    }
}

@MainActor
final class MockLoginItem: LoginItemManaging {
    enum Failure: Error {
        case denied
    }

    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: SMAppService.Status, registerError: Error? = nil, unregisterError: Error? = nil) {
        self.status = status
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    func register() throws {
        registerCount += 1
        if let registerError {
            throw registerError
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError {
            throw unregisterError
        }
        status = .notRegistered
    }
}

@MainActor
final class MockScreenshotWatcher: ScreenshotWatching {
    var isWatching = false
    var watchedFolder: URL?
    var hasStoredFolder = false
    var clipboardManager: ClipboardManager?

    private(set) var promptCallCount = 0
    private(set) var requestNotificationCount = 0
    private(set) var startWatchingFolders: [URL] = []
    private(set) var stopWatchingCount = 0
    private(set) var clearStoredFolderCount = 0

    /// What `promptForFolder` should hand back when invoked. Tests stage this.
    var folderToReturn: URL?

    func promptForFolder() -> URL? {
        promptCallCount += 1
        return folderToReturn
    }

    func resolveBookmark() -> URL? {
        watchedFolder
    }

    func requestNotificationPermission() {
        requestNotificationCount += 1
    }

    func startWatching(folder: URL) {
        startWatchingFolders.append(folder)
        watchedFolder = folder
        isWatching = true
    }

    func stopWatching() {
        stopWatchingCount += 1
        isWatching = false
        watchedFolder = nil
    }

    func clearStoredFolder() {
        clearStoredFolderCount += 1
        hasStoredFolder = false
    }
}

actor MockImageTextExtractor {
    private(set) var requestedImages: [Data] = []
    let text: String?

    init(text: String? = nil) {
        self.text = text
    }

    func extractText(from data: Data) -> String? {
        requestedImages.append(data)
        return text
    }
}

actor DeferredImageTextExtractor {
    private var result: CheckedContinuation<String?, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func extractText(from _: Data) async -> String? {
        await withCheckedContinuation { continuation in
            result = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilRequested() async {
        guard result == nil else { return }
        await withCheckedContinuation { started = $0 }
    }

    func complete(with text: String?) {
        result?.resume(returning: text)
        result = nil
    }
}

final class MockLinkMetadataFetcher: LinkMetadataFetching, @unchecked Sendable {
    private let state: State

    init() {
        state = State()
    }

    var fetchCallCount: Int {
        get async { await state.fetchCallCount }
    }

    func setMetadata(_ metadata: LinkMetadata, for url: URL) async {
        await state.setMetadata(metadata, for: url)
    }

    func fetchMetadata(for url: URL) async -> LinkMetadata {
        await state.fetchMetadata(for: url)
    }

    private actor State {
        var metadataByURL: [URL: LinkMetadata] = [:]
        var fetchCallCount = 0

        func setMetadata(_ metadata: LinkMetadata, for url: URL) {
            metadataByURL[url] = metadata
        }

        func fetchMetadata(for url: URL) -> LinkMetadata {
            fetchCallCount += 1
            return metadataByURL[url] ?? LinkMetadata()
        }
    }
}
