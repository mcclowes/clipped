@testable import Clipped
import Foundation
import Testing

@MainActor
struct HistorySidebarTests {
    private func textItem(app: String?, bundleID: String? = nil) -> ClipboardItem {
        ClipboardItem(
            content: .text("sample"),
            contentType: .plainText,
            sourceAppName: app,
            sourceAppBundleID: bundleID
        )
    }

    @Test("Groups items by source app with per-app counts")
    func groupsByApp() {
        let items = [
            textItem(app: "Safari"),
            textItem(app: "Safari"),
            textItem(app: "Xcode"),
        ]

        let groups = HistoryCategory.sourceAppGroups(from: items)

        #expect(groups.count == 2)
        #expect(groups.first?.name == "Safari")
        #expect(groups.first?.count == 2)
        #expect(groups.last?.name == "Xcode")
        #expect(groups.last?.count == 1)
    }

    @Test("Orders groups by count descending then name")
    func ordersByCountThenName() {
        let items = [
            textItem(app: "Notes"),
            textItem(app: "Mail"),
            textItem(app: "Mail"),
            textItem(app: "Zed"),
        ]

        let groups = HistoryCategory.sourceAppGroups(from: items)

        // Mail (2) leads; Notes and Zed tie at 1 so sort alphabetically.
        #expect(groups.map(\.name) == ["Mail", "Notes", "Zed"])
    }

    @Test("Skips items with no source app name")
    func skipsItemsWithoutApp() {
        let items = [
            textItem(app: nil),
            textItem(app: ""),
            textItem(app: "Slack"),
        ]

        let groups = HistoryCategory.sourceAppGroups(from: items)

        #expect(groups.map(\.name) == ["Slack"])
    }

    @Test("Keeps the first bundle ID seen for an app")
    func capturesBundleID() {
        let items = [
            textItem(app: "Safari", bundleID: nil),
            textItem(app: "Safari", bundleID: "com.apple.Safari"),
        ]

        let groups = HistoryCategory.sourceAppGroups(from: items)

        #expect(groups.first?.bundleID == "com.apple.Safari")
    }

    @Test("App category id and label derive from the app name")
    func appCategoryIdentity() {
        let category = HistoryCategory.app("Visual Studio Code")

        #expect(category.id == "app:Visual Studio Code")
        #expect(category.label == "Visual Studio Code")
    }
}
