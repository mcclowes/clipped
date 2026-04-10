import AppKit
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
    /// Files we've seen appear but are waiting to confirm are fully written before ingesting.
    /// Map: filename → last-observed mtime.
    private var pendingFiles: [String: Date] = [:]
    private var pollTimer: Timer?

    var clipboardManager: ClipboardManager?

    private static let bookmarkKey = "screenshotFolderBookmark"

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
        watchedFolder = folder

        knownFiles = Set(imageFiles(in: folder))

        isWatching = true
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForNewScreenshots()
            }
        }
    }

    func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
        isWatching = false
        watchedFolder?.stopAccessingSecurityScopedResource()
        watchedFolder = nil
        knownFiles = []
    }

    func clearStoredFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    }

    private func checkForNewScreenshots() {
        guard let folder = watchedFolder else { return }

        let currentFiles = Set(imageFiles(in: folder))
        let newlyAppeared = currentFiles.subtracting(knownFiles)

        // Stage new files into `pendingFiles` and wait a poll-cycle so `screencapture`
        // has finished writing before we try to read them.
        for fileName in newlyAppeared where pendingFiles[fileName] == nil {
            let fileURL = folder.appendingPathComponent(fileName)
            if let mtime = modificationDate(of: fileURL) {
                pendingFiles[fileName] = mtime
            }
        }

        // Ingest any pending file whose mtime hasn't moved since the last poll.
        var ingested: [String] = []
        for (fileName, previousMtime) in pendingFiles {
            let fileURL = folder.appendingPathComponent(fileName)
            guard let currentMtime = modificationDate(of: fileURL) else {
                ingested.append(fileName)
                continue
            }
            if currentMtime != previousMtime {
                // File is still being written; remember the new mtime and try again next poll.
                pendingFiles[fileName] = currentMtime
                continue
            }

            defer { ingested.append(fileName) }

            guard let imageData = try? Data(contentsOf: fileURL),
                  let image = NSImage(data: imageData)
            else { continue }

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

            // Show a disappearing notification
            sendScreenshotNotification(fileName: fileName)
        }

        for fileName in ingested {
            pendingFiles.removeValue(forKey: fileName)
        }

        knownFiles = currentFiles
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
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
