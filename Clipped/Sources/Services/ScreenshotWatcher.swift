import AppKit
import Darwin
import Observation
import os
import UserNotifications

@MainActor
@Observable
final class ScreenshotWatcher {
    private static let logger = Logger(subsystem: "com.mcclowes.clipped", category: "ScreenshotWatcher")

    private(set) var isWatching = false
    private(set) var watchedFolder: URL?
    private var knownFiles: Set<String> = []
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1

    var clipboardManager: ClipboardManager?

    private static let bookmarkKey = "screenshotFolderBookmark"

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
        watchedFD = fd
        knownFiles = Set(imageFiles(in: folder))

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
        watchedFD = -1
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

        let currentFiles = Set(imageFiles(in: folder))
        let newlyAppeared = currentFiles.subtracting(knownFiles)
        knownFiles = currentFiles

        guard !newlyAppeared.isEmpty else { return }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard let self, let folder = watchedFolder else { return }
            for fileName in newlyAppeared {
                ingestScreenshot(fileName: fileName, in: folder)
            }
        }
    }

    private func ingestScreenshot(fileName: String, in folder: URL) {
        let fileURL = folder.appendingPathComponent(fileName)
        guard let imageData = try? Data(contentsOf: fileURL),
              let image = NSImage(data: imageData)
        else { return }

        Self.logger.info("New screenshot detected: \(fileName)")
        let item = ClipboardItem(
            content: .image(imageData, image.size),
            contentType: .image,
            sourceAppName: "Screenshot",
            sourceAppBundleID: "com.apple.screencaptureui"
        )
        clipboardManager?.items.insert(item, at: 0)

        // Copy screenshot to system clipboard so user can paste immediately
        clipboardManager?.copyToClipboard(item)

        clipboardManager?.trimToMaxSize()
        clipboardManager?.saveHistory()

        sendScreenshotNotification(fileName: fileName)
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

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]

    private func imageFiles(in folder: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return contents.filter { filename in
            let ext = (filename as NSString).pathExtension.lowercased()
            return Self.imageExtensions.contains(ext)
        }
    }
}
