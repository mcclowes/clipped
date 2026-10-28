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

    @Test("Panel search matches full text and masks flagged OCR", arguments: [false, true], [false, true])
    func panelSearchPrivacy(sensitive: Bool, secret: Bool) {
        let history = ClipboardHistory()
        let image = ClipboardItem(
            content: .image(Data([1]), CGSize(width: 1, height: 1)), contentType: .image,
            isSensitive: sensitive, containsSecret: secret
        )
        image.extractedText = "Needle in OCR"
        let text = ClipboardItem(
            content: .text(String(repeating: "x", count: 250) + "needle"), contentType: .plainText
        )
        history.items = [image, text]
        history.searchQuery = "nEeDlE"

        let expected = sensitive || secret ? [text.id] : [image.id, text.id]
        #expect(history.filteredItems.map(\.id) == expected)
        let library = ClipboardFilter.apply(
            to: history.items,
            query: history.searchQuery,
            matching: HistoryCategory.all.includes
        )
        #expect(library.map(\.id) == expected)
        history.searchQuery = ""
        #expect(history.filteredItems.map(\.id) == [image.id, text.id])
    }

    @Test("Panel criteria retain their content, tag, and source distinctions")
    func panelFilterCriteria() throws {
        let history = ClipboardHistory()
        let plain = ClipboardItem(
            content: .text("mail"), contentType: .plainText, sourceAppBundleID: "com.apple.Safari",
            detectedCategories: [.email]
        )
        let rich = ClipboardItem(content: .richText(Data([1]), "formatted"), contentType: .richText)
        let link = try ClipboardItem(content: .url(#require(URL(string: "https://example.invalid"))), contentType: .url)
        let svg = ClipboardItem(content: .svg(Data("<svg/>".utf8), .zero), contentType: .image)
        svg.isDeveloperContent = true
        history.items = [plain, rich, link, svg]
        let cases: [(ClipboardFilter?, [UUID])] = [
            (nil, [plain.id, rich.id, link.id, svg.id]),
            (.text, [plain.id, rich.id]),
            (.contentType(.plainText), [plain.id]),
            (.contentType(.url), [link.id]),
            (.contentType(.image), [svg.id]),
            (.developer, [svg.id]),
            (.category(.email), [plain.id]),
            (.sourceApp(.browser), [plain.id]),
        ]
        for (filter, expected) in cases {
            history.selectedFilter = filter
            #expect(history.filteredItems.map(\.id) == expected)
        }
    }

    @Test("Library criteria preserve app names, SVG images, and result order")
    func libraryFilterCriteria() throws {
        let plain = ClipboardItem(content: .text("needle"), contentType: .plainText, sourceAppName: "Safari")
        let rich = ClipboardItem(
            content: .richText(Data([1]), "needle"),
            contentType: .richText,
            sourceAppName: "Xcode"
        )
        let link = try ClipboardItem(
            content: .url(#require(URL(string: "https://example.invalid/needle"))), contentType: .url,
            sourceAppName: "Safari"
        )
        let svg = ClipboardItem(content: .svg(Data("<svg>needle</svg>".utf8), .zero), contentType: .image)
        svg.isDeveloperContent = true
        let source = [plain, rich, link, svg]
        let cases: [(HistoryCategory, [UUID])] = [
            (.all, source.map(\.id)),
            (.pinned, source.map(\.id)),
            (.text, [plain.id, rich.id]),
            (.urls, [link.id]),
            (.images, [svg.id]),
            (.developer, [svg.id]),
            (.app("Safari"), [plain.id, link.id]),
            (.app("safari"), []),
        ]
        for (category, expected) in cases {
            let result = ClipboardFilter.apply(to: source, query: "NEEDLE", matching: category.includes)
            #expect(result.map(\.id) == expected)
        }
    }
}
