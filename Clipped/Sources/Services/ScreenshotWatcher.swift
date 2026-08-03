import AppKit
import Darwin
import Observation
import os
import UserNotifications

/// Image file extensions treated as screenshots. File-scoped so the nonisolated static
/// `imageFiles(in:)` scanner can read it without actor-isolation gymnastics.
private let screenshotImageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]

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
    /// Not observable (an implementation detail); `nonisolated(unsafe)` lets the nonisolated
    /// `deinit` cancel it. Only ever mutated on the main actor, and by deinit no other reference
    /// to this watcher survives, so the access is race-free.
    @ObservationIgnored nonisolated(unsafe) var dispatchSource: DispatchSourceFileSystemObject?

    var clipboardManager: ClipboardManager?

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

    var hasStoredFolder: Bool {
        UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil
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
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }

        return url
    }

    func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
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
                UserDefaults.standard.set(newBookmark, forKey: Self.bookmarkKey)
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
        dispatchSource?.cancel()
        dispatchSource = nil
        isWatching = false
        watchedFolder?.stopAccessingSecurityScopedResource()
        watchedFolder = nil
        knownFiles = []
    }

    func clearStoredFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    }

    private func handleDirectoryChange() {
        guard let folder = watchedFolder else { return }

        Task { [weak self] in
            guard let self else { return }
            // Enumerate the directory off the main actor — it scales with folder size.
            let currentFiles = await Self.imageFilesAsync(in: folder)
            let newlyAppeared = currentFiles.subtracting(knownFiles)
            knownFiles = currentFiles
            guard !newlyAppeared.isEmpty else { return }

            // Give `screencapture` time to flush the file's bytes before we read it.
            try? await Task.sleep(for: Self.settleDelay)
            guard watchedFolder == folder else { return }
            for fileName in newlyAppeared {
                await ingestScreenshot(fileName: fileName, in: folder)
            }
        }
    }

    private func ingestScreenshot(fileName: String, in folder: URL) async {
        let fileURL = folder.appendingPathComponent(fileName)
        // Read + decode off the main actor so a multi-MB screenshot doesn't stall the UI.
        let decoded = await Task.detached(priority: .utility) { () -> (Data, CGSize)? in
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            guard let size = ImageProcessor.pixelSize(of: data) ?? NSImage(data: data)?.size else { return nil }
            return (data, size)
        }.value

        guard let (imageData, size) = decoded else {
            // The bytes weren't ready yet (still flushing). Forget the name so a later write
            // event re-attempts ingestion instead of dropping the screenshot permanently.
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
        clipboardManager?.history.insert(item)

        // Copy screenshot to system clipboard so user can paste immediately.
        clipboardManager?.copyToClipboard(item)

        clipboardManager?.trimToMaxSize()
        clipboardManager?.saveHistory()

        sendScreenshotNotification(fileName: fileName)
        offerFloatingThumbnailTipIfNeeded()
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

    private func sendScreenshotNotification(fileName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Screenshot captured"
        content.body = "Copied to clipboard — ready to paste"

        let request = UNNotificationRequest(
            identifier: "screenshot-\(fileName)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
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
