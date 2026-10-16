import AppKit
import Darwin
import Observation
import os
import UserNotifications

/// Image file extensions treated as screenshots. File-scoped so the nonisolated static
/// `imageFiles(in:)` scanner can read it without actor-isolation gymnastics.
private let screenshotImageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]
private let screenCaptureMetadataKey = "com.apple.metadata:kMDItemIsScreenCapture"
private let maxScreenCaptureMetadataBytes = 4096

/// Abstraction over the screenshot directory watcher so tests and alternative
/// implementations can stand in. Mirrors `SettingsManaging` and
/// `LinkMetadataFetching`: views keep using the concrete `ScreenshotWatcher`
/// via `@Environment(ScreenshotWatcher.self)`, while internal call sites and
/// future mocks talk to the protocol.
@MainActor
protocol ScreenshotWatching: AnyObject {
    var isWatching: Bool { get }
    var watchedFolder: URL? { get }
    var hasStoredFolder: Bool { get }
    var clipboardManager: ClipboardManager? { get set }

    func promptForFolder() -> URL?
    func resolveBookmark() -> URL?
    func requestNotificationPermission()
    func startWatching(folder: URL)
    func stopWatching()
    func clearStoredFolder()
}

@MainActor
@Observable
final class ScreenshotWatcher: ScreenshotWatching {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "ScreenshotWatcher")

    private(set) var isWatching = false
    private(set) var watchedFolder: URL?
    private var knownFiles: Set<String> = []
    @ObservationIgnored private var watchGeneration = UUID()
    @ObservationIgnored private var pendingCaptures: [String: Task<Void, Never>] = [:]
    /// Not observable (an implementation detail); `nonisolated(unsafe)` lets the nonisolated
    /// `deinit` cancel it. Only ever mutated on the main actor, and by deinit no other reference
    /// to this watcher survives, so the access is race-free.
    @ObservationIgnored nonisolated(unsafe) var dispatchSource: DispatchSourceFileSystemObject?

    var clipboardManager: ClipboardManager?

    @ObservationIgnored
    var notifyScreenshot: (String, Bool) -> Void = { fileName, copied in
        ScreenshotWatcher.sendScreenshotNotification(fileName: fileName, copied: copied)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let floatingThumbnailEnabled: @MainActor () -> Bool
    @ObservationIgnored private let presentFloatingThumbnailTip: @MainActor () -> Void

    init() {
        defaults = .standard
        floatingThumbnailEnabled = { ScreenshotWatcher.isFloatingThumbnailEnabled() }
        presentFloatingThumbnailTip = { ScreenshotWatcher.presentFloatingThumbnailTip() }
    }

    init(
        defaults: UserDefaults,
        floatingThumbnailEnabled: @escaping @MainActor () -> Bool,
        presentFloatingThumbnailTip: @escaping @MainActor () -> Void
    ) {
        self.defaults = defaults
        self.floatingThumbnailEnabled = floatingThumbnailEnabled
        self.presentFloatingThumbnailTip = presentFloatingThumbnailTip
    }

    deinit {
        // Cancelling triggers the source's cancel handler, which closes the file descriptor.
        // Without this a watcher deallocated while active would leak both.
        dispatchSource?.cancel()
    }

    private static let bookmarkKey = "screenshotFolderBookmark"
    private static let floatingThumbnailTipKey = "hasShownFloatingThumbnailTip"

    /// Short settle delay after a directory change before reading new files, so `screencapture`
    /// has time to flush its write when it creates the file entry before writing the image bytes.
    private static let settleDelay: Duration = .milliseconds(250)
    private static let readAttempts = 12

    var hasStoredFolder: Bool {
        defaults.data(forKey: Self.bookmarkKey) != nil
    }

    func promptForFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the folder where macOS saves screenshots"
        panel.prompt = "Select"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(bookmark, forKey: Self.bookmarkKey)
        }

        return url
    }

    func resolveBookmark() -> URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale {
            if let newBookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                defaults.set(newBookmark, forKey: Self.bookmarkKey)
            }
        }

        return url
    }

    func requestNotificationPermission() {
        Task {
            try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    func startWatching(folder: URL) {
        stopWatching()

        guard folder.startAccessingSecurityScopedResource() else {
            Self.logger.error("Failed to access security-scoped resource for screenshot folder")
            return
        }

        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            Self.logger.error("Failed to open folder for watching: \(folder.path)")
            folder.stopAccessingSecurityScopedResource()
            return
        }

        watchedFolder = folder
        knownFiles = Set(Self.imageFiles(in: folder))

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { @Sendable [weak self] in
            Task { @MainActor in
                self?.handleDirectoryChange()
            }
        }
        source.setCancelHandler { @Sendable [fd] in
            close(fd)
        }
        dispatchSource = source
        source.resume()

        isWatching = true
    }

    func stopWatching() {
        watchGeneration = UUID()
        for task in pendingCaptures.values {
            task.cancel()
        }
        pendingCaptures = [:]
        dispatchSource?.cancel()
        dispatchSource = nil
        isWatching = false
        watchedFolder?.stopAccessingSecurityScopedResource()
        watchedFolder = nil
        knownFiles = []
    }

    func clearStoredFolder() {
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    private func handleDirectoryChange() {
        guard let folder = watchedFolder else { return }
        let generation = watchGeneration

        Task { [weak self] in
            guard let self else { return }
            // Enumerate the directory off the main actor — it scales with folder size.
            let currentFiles = await Self.imageFilesAsync(in: folder)
            guard watchGeneration == generation else { return }
            let newlyAppeared = currentFiles.subtracting(knownFiles)
            knownFiles = currentFiles
            for fileName in newlyAppeared where pendingCaptures[fileName] == nil {
                pendingCaptures[fileName] = Task { [weak self] in
                    do {
                        try await Task.sleep(for: Self.settleDelay)
                    } catch {
                        return
                    }
                    guard let self, watchGeneration == generation else { return }
                    defer {
                        if watchGeneration == generation {
                            pendingCaptures[fileName] = nil
                        }
                    }
                    await ingestScreenshot(fileName: fileName, in: folder)
                }
            }
        }
    }

    func ingestScreenshot(fileName: String, in folder: URL) async {
        let originalChangeCount = clipboardManager?.monitor.pasteboard.changeCount
        let fileURL = folder.appendingPathComponent(fileName)
        let decoded = await Self.readScreenshot(at: fileURL)
        guard !Task.isCancelled else { return }

        guard let (imageData, size) = decoded else {
            // A later directory event can retry files that outlast the bounded readiness window.
            knownFiles.remove(fileName)
            return
        }

        Self.logger.info("New screenshot detected: \(fileName)")
        let item = ClipboardItem(
            content: .image(imageData, size),
            contentType: .image,
            sourceAppName: "Screenshot",
            sourceAppBundleID: "com.apple.screencaptureui"
        )
        guard let clipboardManager, clipboardManager.ingest(PasteboardMonitor.NewItemEvent(
            item: item,
            bundleID: item.sourceAppBundleID,
            hasConcealedType: false
        )) else { return }

        var shouldCopy = clipboardManager.settingsManager?.copyScreenshotsToClipboard == true
        if shouldCopy {
            await clipboardManager.awaitPendingEnrichment(for: item.id)
            guard !Task.isCancelled else { return }
            shouldCopy = clipboardManager.settingsManager?.copyScreenshotsToClipboard == true
                && clipboardManager.monitor.pasteboard.changeCount == originalChangeCount
                && !item.isAwaitingImageText
                && (clipboardManager.items + clipboardManager.pinnedItems).contains { $0.id == item.id }
        }
        if shouldCopy {
            clipboardManager.copyToClipboard(item) { [weak self] in
                self?.notifyScreenshot(fileName, true)
            }
        } else {
            notifyScreenshot(fileName, false)
        }
        offerFloatingThumbnailTipIfNeeded()
    }

    private static func readScreenshot(at fileURL: URL) async -> (Data, CGSize)? {
        // File-content and metadata updates need not generate another directory event.
        for attempt in 0..<readAttempts {
            guard !Task.isCancelled else { return nil }
            let decoded = await Task.detached(priority: .utility) { () -> (Data, CGSize)? in
                guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= PasteboardMonitor.maxImageBytes,
                      Self.hasScreenCaptureMetadata(fileURL),
                      let data = try? Data(contentsOf: fileURL),
                      data.count <= PasteboardMonitor.maxImageBytes else { return nil }
                guard let size = ImageProcessor.pixelSize(of: data) ?? NSImage(data: data)?.size else { return nil }
                return (data, size)
            }.value
            if let decoded {
                return decoded
            }
            guard attempt < readAttempts - 1 else { return nil }
            do {
                try await Task.sleep(for: settleDelay)
            } catch {
                return nil
            }
        }
        return nil
    }

    func offerFloatingThumbnailTipIfNeeded() {
        guard !defaults.bool(forKey: Self.floatingThumbnailTipKey), floatingThumbnailEnabled() else { return }

        // Mark this before presenting so simultaneous directory events cannot queue duplicate alerts.
        defaults.set(true, forKey: Self.floatingThumbnailTipKey)
        presentFloatingThumbnailTip()
    }

    private static func isFloatingThumbnailEnabled() -> Bool {
        let value = CFPreferencesCopyAppValue(
            "show-thumbnail" as CFString,
            "com.apple.screencapture" as CFString
        )
        // macOS enables the floating thumbnail by default, so a missing preference means enabled.
        return (value as? NSNumber)?.boolValue ?? true
    }

    private static func presentFloatingThumbnailTip() {
        let alert = NSAlert()
        alert.messageText = "Get screenshots into Clipped faster"
        alert.informativeText = "macOS waits a few seconds before saving screenshots while the floating thumbnail "
            + "is visible. Turn off Show Floating Thumbnail in Screenshot options to capture them sooner."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Screenshot options")
        alert.addButton(withTitle: "Don't show again")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let screenshotApp = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        NSWorkspace.shared.openApplication(at: screenshotApp, configuration: .init())
    }

    private static func sendScreenshotNotification(fileName: String, copied: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Screenshot captured"
        content.body = copied ? "Copied to clipboard, ready to paste" : "Added to clipboard history"

        let request = UNNotificationRequest(
            identifier: "screenshot-\(fileName)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // swiftformat:disable:next modifierOrder
    nonisolated private static func hasScreenCaptureMetadata(_ url: URL) -> Bool {
        var data = Data(count: maxScreenCaptureMetadataBytes)
        let count = url.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else { return -1 }
            return data.withUnsafeMutableBytes { buffer in
                getxattr(path, screenCaptureMetadataKey, buffer.baseAddress, buffer.count, 0, 0)
            }
        }
        guard count > 0 else { return false }
        data.count = count
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let flag = value as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID() else { return false }
        return flag.boolValue
    }

    nonisolated static func imageFiles(in folder: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return contents.filter { filename in
            let ext = (filename as NSString).pathExtension.lowercased()
            return screenshotImageExtensions.contains(ext)
        }
    }

    private static func imageFilesAsync(in folder: URL) async -> Set<String> {
        await Task.detached(priority: .utility) { Set(imageFiles(in: folder)) }.value
    }
}
