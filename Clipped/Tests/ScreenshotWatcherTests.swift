@testable import Clipped
import Foundation
import Testing

@MainActor
struct ScreenshotWatcherTests {
    private static let bookmarkKey = "screenshotFolderBookmark"

    @Test(
        "Delayed screenshots are captured once unless watching stops",
        .bug(id: 166),
        arguments: [false, true], [false, true]
    )
    func capturesDelayedScreenshot(_ delayedMetadata: Bool, _ stopBeforeReady: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suiteName = "ScreenshotWatcherTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let watcher = makeWatcher(defaults: defaults)
        defer { watcher.stopWatching() }
        let pasteboard = MockPasteboard()
        let manager = ClipboardManager(pasteboard: pasteboard)
        manager.stopMonitoring()
        manager.historyStore = MockHistoryStore()
        let settings = MockSettingsManager()
        settings.copyScreenshotsToClipboard = true
        manager.settingsManager = settings
        manager.extractImageText = { _ in nil }
        watcher.clipboardManager = manager
        var notifications = 0
        watcher.notifyScreenshot = { _, _ in notifications += 1 }
        watcher.startWatching(folder: folder)
        try #require(watcher.isWatching)

        let file = folder.appendingPathComponent("Screenshot.png")
        let image = TestImageFactory.data(width: 40, height: 30)
        try (delayedMetadata ? image : Data()).write(to: file)
        if delayedMetadata == false {
            try ScreenshotMetadataFixture.mark(file)
        }
        try await Task.sleep(for: .milliseconds(900))
        #expect(manager.items.isEmpty)
        if stopBeforeReady {
            watcher.stopWatching()
        }

        // Updating an existing file need not send another directory-entry event.
        if delayedMetadata {
            try ScreenshotMetadataFixture.mark(file)
        } else {
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: image)
            try handle.close()
        }
        let deadline = ContinuousClock.now + .seconds(stopBeforeReady ? 1 : 3)
        while notifications == 0 || stopBeforeReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(manager.items.count == (stopBeforeReady ? 0 : 1))
        #expect(notifications == (stopBeforeReady ? 0 : 1))
        #expect(pasteboard.data(forType: .png) == (stopBeforeReady ? nil : image))
        try Data().write(to: folder.appendingPathComponent("unrelated.txt"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(manager.items.count == (stopBeforeReady ? 0 : 1))
        #expect(notifications == (stopBeforeReady ? 0 : 1))
    }

    @Test("Offers the floating-thumbnail tip once when the macOS feature is enabled")
    func offersTipOnce() throws {
        try withDefaults { defaults in
            var presentationCount = 0
            let watcher = ScreenshotWatcher(
                defaults: defaults,
                floatingThumbnailEnabled: { true },
                presentFloatingThumbnailTip: { presentationCount += 1 }
            )

            watcher.offerFloatingThumbnailTipIfNeeded()
            watcher.offerFloatingThumbnailTipIfNeeded()

            #expect(presentationCount == 1)
        }
    }

    @Test("Doesn't offer the tip when the floating thumbnail is disabled")
    func skipsTipWhenDisabled() throws {
        try withDefaults { defaults in
            var presentationCount = 0
            let watcher = ScreenshotWatcher(
                defaults: defaults,
                floatingThumbnailEnabled: { false },
                presentFloatingThumbnailTip: { presentationCount += 1 }
            )

            watcher.offerFloatingThumbnailTipIfNeeded()

            #expect(presentationCount == 0)
        }
    }

    @Test("Folder-bookmark presence comes from each watcher's preferences", .bug(id: 165))
    func bookmarkPresenceUsesInjectedStore() throws {
        try withDefaults { populated in
            try withDefaults { empty in
                populated.set(Data([0x01]), forKey: Self.bookmarkKey)

                #expect(makeWatcher(defaults: populated).hasStoredFolder)
                #expect(makeWatcher(defaults: empty).hasStoredFolder == false)
            }
        }
    }

    @Test("Clearing a folder bookmark affects only the watcher's preferences", .bug(id: 165))
    func clearsOnlyInjectedBookmark() throws {
        try withDefaults { first in
            try withDefaults { second in
                first.set(Data([0x01]), forKey: Self.bookmarkKey)
                let retained = Data([0x02])
                second.set(retained, forKey: Self.bookmarkKey)
                let watcher = makeWatcher(defaults: first)

                watcher.clearStoredFolder()

                #expect(first.data(forKey: Self.bookmarkKey) == nil)
                #expect(watcher.hasStoredFolder == false)
                #expect(second.data(forKey: Self.bookmarkKey) == retained)
                #expect(makeWatcher(defaults: second).hasStoredFolder)
            }
        }
    }

    @Test("Resolves the folder bookmark from the watcher's preferences", .bug(id: 165))
    func resolvesInjectedBookmark() throws {
        try withDefaults { defaults in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ScreenshotBookmarkTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let data = try folder.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: Self.bookmarkKey)

            let resolved = try #require(makeWatcher(defaults: defaults).resolveBookmark())

            #expect(resolved.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        }
    }

    @Test("Malformed folder bookmarks stay in their own preferences", .bug(id: 165), arguments: [
        Data(),
        Data([0x01]),
    ])
    func rejectsMalformedBookmark(_ data: Data) throws {
        try withDefaults { defaults in
            defaults.set(data, forKey: Self.bookmarkKey)

            #expect(makeWatcher(defaults: defaults).resolveBookmark() == nil)
            #expect(defaults.data(forKey: Self.bookmarkKey) == data)
        }
    }

    private func makeWatcher(defaults: UserDefaults) -> ScreenshotWatcher {
        ScreenshotWatcher(
            defaults: defaults,
            floatingThumbnailEnabled: { false },
            presentFloatingThumbnailTip: {}
        )
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "ScreenshotWatcherTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
