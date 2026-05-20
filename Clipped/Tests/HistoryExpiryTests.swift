@testable import Clipped
import Foundation
import Testing

@MainActor
struct HistoryExpiryTests {
    private func makeHistory(retention: HistoryRetention) -> (ClipboardHistory, MockSettingsManager) {
        let history = ClipboardHistory()
        let settings = MockSettingsManager()
        settings.historyRetention = retention
        history.settingsManager = settings
        return (history, settings)
    }

    private func textItem(_ string: String, ageDays: Double, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(
            content: .text(string),
            contentType: .plainText,
            timestamp: Date().addingTimeInterval(-ageDays * 24 * 60 * 60),
            isPinned: pinned
        )
    }

    // MARK: - HistoryRetention

    @Test("`.never` reports no expiry interval so expiry stays disabled")
    func neverDisablesExpiry() {
        #expect(HistoryRetention.never.interval == nil)
    }

    @Test("Other cases report the expected number of seconds")
    func intervalValues() {
        let day: TimeInterval = 86400
        #expect(HistoryRetention.oneDay.interval == day)
        #expect(HistoryRetention.sevenDays.interval == 7 * day)
        #expect(HistoryRetention.thirtyDays.interval == 30 * day)
        #expect(HistoryRetention.ninetyDays.interval == 90 * day)
    }

    // MARK: - trimExpiredItems

    @Test("Items older than retention are evicted, fresh items survive")
    func evictsOldItems() {
        let (history, _) = makeHistory(retention: .sevenDays)
        history.items = [
            textItem("fresh", ageDays: 1),
            textItem("stale", ageDays: 10),
        ]

        history.trimExpiredItems()

        #expect(history.items.map(\.preview) == ["fresh"])
    }

    @Test("Pinned items are exempt from expiry")
    func pinnedAreExempt() {
        let (history, _) = makeHistory(retention: .oneDay)
        let pinned = textItem("kept", ageDays: 30, pinned: true)
        history.pinnedItems = [pinned]
        history.items = [textItem("dropped", ageDays: 30)]

        history.trimExpiredItems()

        #expect(history.items.isEmpty)
        #expect(history.pinnedItems.count == 1)
    }

    @Test("`.never` retention is a no-op even with very old items")
    func neverIsNoOp() {
        let (history, _) = makeHistory(retention: .never)
        history.items = [textItem("ancient", ageDays: 365)]

        history.trimExpiredItems()

        #expect(history.items.count == 1)
    }

    @Test("Items right at the boundary are evicted")
    func boundary() {
        let (history, _) = makeHistory(retention: .oneDay)
        let now = Date()
        // Two seconds beyond the 1-day cutoff — must be removed.
        let stale = ClipboardItem(
            content: .text("stale"),
            contentType: .plainText,
            timestamp: now.addingTimeInterval(-86400 - 2)
        )
        history.items = [stale]

        history.trimExpiredItems(now: now)

        #expect(history.items.isEmpty)
    }
}
