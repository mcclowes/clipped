import Foundation

enum ClipboardFilter: Hashable, Identifiable {
    case contentType(ContentType)
    case text // combines plainText + richText
    case developer
    case category(ContentCategory)
    case sourceApp(SourceAppCategory)

    @MainActor
    func includes(_ item: ClipboardItem) -> Bool {
        switch self {
        case let .contentType(type): item.contentType == type
        case .text: item.contentType == .plainText || item.contentType == .richText
        case .developer: item.isDeveloperContent
        case let .category(category): item.detectedCategories.contains(category)
        case let .sourceApp(category): item.sourceAppCategory == category
        }
    }

    @MainActor
    static func apply(
        to items: [ClipboardItem],
        query: String,
        matching criterion: @MainActor (ClipboardItem) -> Bool
    ) -> [ClipboardItem] {
        items.filter { item in
            guard criterion(item) else { return false }
            guard !query.isEmpty else { return true }
            if item.searchableText.localizedCaseInsensitiveContains(query) {
                return true
            }
            // Masked OCR must not reveal secrets through search results.
            guard !item.isSensitive, !item.containsSecret else { return false }
            return item.extractedText?.localizedCaseInsensitiveContains(query) ?? false
        }
    }

    var id: String {
        switch self {
        case let .contentType(type): type.rawValue
        case .text: "Text"
        case .developer: "Developer"
        case let .category(cat): "Category.\(cat.rawValue)"
        case let .sourceApp(app): "SourceApp.\(app.rawValue)"
        }
    }

    var label: String {
        switch self {
        case let .contentType(type): type.rawValue
        case .text: "Text"
        case .developer: "Dev"
        case let .category(cat): cat.label
        case let .sourceApp(app): app.label
        }
    }

    var systemImage: String {
        switch self {
        case let .contentType(type): type.systemImage
        case .text: "doc.text"
        case .developer: "curlybraces"
        case let .category(cat): cat.systemImage
        case let .sourceApp(app): app.systemImage
        }
    }

    var settingsDescription: String {
        switch self {
        case .text:
            "Plain and rich text items"
        case .contentType(.url):
            "Web links"
        case .contentType(.image):
            "Screenshots and other images"
        case .developer:
            "UUIDs, JSON, JWTs, hashes, code blocks, file paths"
        case .contentType(.plainText):
            "Plain text only"
        case .contentType(.richText):
            "Rich text only"
        case let .category(cat):
            cat.settingsDescription
        case let .sourceApp(app):
            app.settingsDescription
        }
    }

    /// Filter categories the user can show or hide in the panel's tab bar.
    /// "All" is implicit — it is always shown as the default selection.
    /// Composed from the three sub-groups so the ordering stays in sync with Settings.
    static var toggleableCategories: [ClipboardFilter] {
        contentTypeFilters + smartCategoryFilters + sourceAppFilters
    }

    /// IDs of filter tabs that default to hidden on first launch. Keeps the strip tidy for
    /// existing users while still letting new users discover the extended set via settings.
    static let defaultHiddenCategoryIDs: Set<String> = [
        ClipboardFilter.category(.email).id,
        ClipboardFilter.category(.phoneNumber).id,
        ClipboardFilter.category(.hexColor).id,
        ClipboardFilter.category(.number).id,
        ClipboardFilter.category(.ipAddress).id,
        ClipboardFilter.category(.macAddress).id,
        ClipboardFilter.sourceApp(.communication).id,
        ClipboardFilter.sourceApp(.browser).id,
        ClipboardFilter.sourceApp(.codeEditor).id,
        ClipboardFilter.sourceApp(.terminal).id,
    ]

    static let contentTypeFilters: [ClipboardFilter] = [
        .text,
        .contentType(.url),
        .developer,
        .contentType(.image),
    ]

    static let smartCategoryFilters: [ClipboardFilter] = ContentCategory.allCases.map(ClipboardFilter.category)

    static let sourceAppFilters: [ClipboardFilter] = SourceAppCategory.allCases.map(ClipboardFilter.sourceApp)
}

enum HistoryCategory: Hashable, Identifiable {
    case all
    case pinned
    case text
    case urls
    case images
    case developer
    /// Items copied from a specific source app, keyed by its display name.
    case app(String)

    var id: String {
        switch self {
        case .all: "all"
        case .pinned: "pinned"
        case .text: "text"
        case .urls: "urls"
        case .images: "images"
        case .developer: "developer"
        case let .app(name): "app:\(name)"
        }
    }

    var label: String {
        switch self {
        case .all: "All Items"
        case .pinned: "Pinned"
        case .text: "Text"
        case .urls: "Links"
        case .images: "Images"
        case .developer: "Developer"
        case let .app(name): name
        }
    }
}

// MARK: - Source app grouping

/// One source app present in the clipboard history, with how many items came from it.
/// Drives the "Applications" section of the history sidebar.
struct SourceAppGroup: Identifiable, Hashable {
    let name: String
    let bundleID: String?
    let count: Int

    var id: String {
        name
    }
}

extension HistoryCategory {
    /// Buckets `items` by their source app, ordered by item count descending then name
    /// so the busiest apps surface first. Items without a `sourceAppName` are skipped.
    @MainActor
    static func sourceAppGroups(from items: [ClipboardItem]) -> [SourceAppGroup] {
        var counts: [String: Int] = [:]
        var bundleIDs: [String: String] = [:]
        var order: [String] = []

        for item in items {
            guard let name = item.sourceAppName, !name.isEmpty else { continue }
            if counts[name] == nil {
                order.append(name)
            }
            counts[name, default: 0] += 1
            // Keep the first non-nil bundle ID seen for the app.
            if bundleIDs[name] == nil, let bundleID = item.sourceAppBundleID {
                bundleIDs[name] = bundleID
            }
        }

        return order
            .map { SourceAppGroup(name: $0, bundleID: bundleIDs[$0], count: counts[$0] ?? 0) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count
                    ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    : lhs.count > rhs.count
            }
    }
}

extension HistoryCategory {
    @MainActor
    func includes(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all, .pinned: true
        case .text: ClipboardFilter.text.includes(item)
        case .urls: ClipboardFilter.contentType(.url).includes(item)
        case .images: ClipboardFilter.contentType(.image).includes(item)
        case .developer: ClipboardFilter.developer.includes(item)
        case let .app(name): item.sourceAppName == name
        }
    }
}
