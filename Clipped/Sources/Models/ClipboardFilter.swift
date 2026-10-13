enum ClipboardFilter: Hashable, Identifiable {
    case contentType(ContentType)
    case text // combines plainText + richText
    case developer
    case category(ContentCategory)
    case sourceApp(SourceAppCategory)

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
