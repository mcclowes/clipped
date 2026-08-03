@testable import Clipped
import Foundation
import Testing

@MainActor
struct ScreenshotWatcherTests {
    @Test("Offers the floating-thumbnail tip once when the macOS feature is enabled")
    func offersTipOnce() throws {
        let defaults = try freshDefaults()
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

    @Test("Doesn't offer the tip when the floating thumbnail is disabled")
    func skipsTipWhenDisabled() throws {
        let defaults = try freshDefaults()
        var presentationCount = 0
        let watcher = ScreenshotWatcher(
            defaults: defaults,
            floatingThumbnailEnabled: { false },
            presentFloatingThumbnailTip: { presentationCount += 1 }
        )

        watcher.offerFloatingThumbnailTipIfNeeded()

        #expect(presentationCount == 0)
    }

    private func freshDefaults(function: String = #function) throws -> UserDefaults {
        let suiteName = "ScreenshotWatcherTests.\(function).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
