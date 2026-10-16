@testable import Clipped
import Foundation
import Testing

@MainActor
struct ScreenshotWatcherTests {
    private static let bookmarkKey = "screenshotFolderBookmark"

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
