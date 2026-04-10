import AppKit
import SwiftUI

/// Full clipboard history browser. Opened from the menu bar panel via "See full history".
///
/// Uses a three-column `NavigationSplitView` layout: sidebar categories, item list with
/// search, and a detail pane that previews the selected item with its metadata + actions.
/// Unlike `ClipboardPanelView` this is not capped — it shows the entire retained history.
struct HistoryWindowView: View {
    @Environment(ClipboardManager.self) private var manager
    @Environment(\.openWindow) private var openWindow

    @State private var selectedCategory: HistoryCategory = .all
    @State private var selectedItemID: ClipboardItem.ID?
    @State private var searchQuery = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            itemList
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 460)
        .onChange(of: selectedCategory) {
            // Reset the selected item whenever the category changes so the detail pane
            // doesn't continue showing something that isn't in the current list.
            selectedItemID = displayedItems.first?.id
        }
        .onChange(of: searchQuery) {
            if let id = selectedItemID, !displayedItems.contains(where: { $0.id == id }) {
                selectedItemID = displayedItems.first?.id
            }
        }
        .onAppear {
            if selectedItemID == nil {
                selectedItemID = displayedItems.first?.id
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedCategory) {
            Section("Library") {
                sidebarRow(.all, label: "All Items", systemImage: "clock", count: totalCount)
                sidebarRow(.pinned, label: "Pinned", systemImage: "pin.fill", count: manager.pinnedItems.count)
            }

            Section("Content") {
                sidebarRow(.text, label: "Text", systemImage: "doc.text", count: count(for: .text))
                sidebarRow(.urls, label: "Links", systemImage: "link", count: count(for: .urls))
                sidebarRow(.images, label: "Images", systemImage: "photo", count: count(for: .images))
                sidebarRow(.developer, label: "Developer", systemImage: "curlybraces", count: count(for: .developer))
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    }

    private func sidebarRow(
        _ category: HistoryCategory,
        label: String,
        systemImage: String,
        count: Int
    ) -> some View {
        NavigationLink(value: category) {
            HStack {
                Label(label, systemImage: systemImage)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Item list

    private var itemList: some View {
        List(selection: $selectedItemID) {
            ForEach(displayedItems) { item in
                HistoryItemRow(item: item)
                    .tag(Optional(item.id))
                    .contextMenu { itemContextMenu(for: item) }
            }
        }
        .listStyle(.inset)
        .navigationTitle(selectedCategory.label)
        .navigationSubtitle("\(displayedItems.count) item\(displayedItems.count == 1 ? "" : "s")")
        .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search history")
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let item = selectedItem {
                        manager.togglePin(item)
                    }
                } label: {
                    Label(
                        selectedItem?.isPinned == true ? "Unpin" : "Pin",
                        systemImage: selectedItem?.isPinned == true ? "pin.slash" : "pin"
                    )
                }
                .disabled(selectedItem == nil)
                .help(selectedItem?.isPinned == true ? "Unpin selected item" : "Pin selected item")

                Button(role: .destructive) {
                    if let item = selectedItem {
                        manager.removeItem(item)
                        selectedItemID = displayedItems.first?.id
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selectedItem == nil)
                .help("Delete selected item")
            }
        }
    }

    @ViewBuilder
    private func itemContextMenu(for item: ClipboardItem) -> some View {
        Button("Copy") { manager.copyToClipboard(item) }

        if case .richText = item.content {
            Button("Copy as plain text") { manager.copyToClipboard(item, asPlainText: true) }
            Button("Copy as Markdown") { manager.copyAsMarkdown(item) }
        }

        Button("Paste and match style") { manager.pasteMatchingStyle(item) }

        if case let .url(url) = item.content {
            Button("Open URL") { NSWorkspace.shared.open(url) }
        }

        Button("Open as sticky note") { openWindow(value: item.id) }

        Divider()

        Button(item.isPinned ? "Unpin" : "Pin") { manager.togglePin(item) }

        Divider()

        Button("Delete", role: .destructive) {
            manager.removeItem(item)
            if selectedItemID == item.id {
                selectedItemID = displayedItems.first?.id
            }
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let item = selectedItem {
            HistoryDetailView(item: item) {
                manager.copyToClipboard(item)
            }
        } else {
            placeholderDetail
        }
    }

    private var placeholderDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Select an item")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Choose a clipboard entry from the list to view or copy it.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private var totalCount: Int {
        manager.items.count + manager.pinnedItems.count
    }

    private func count(for category: HistoryCategory) -> Int {
        items(for: category).count
    }

    private func items(for category: HistoryCategory) -> [ClipboardItem] {
        let merged = manager.pinnedItems + manager.items
        switch category {
        case .all:
            return merged
        case .pinned:
            return manager.pinnedItems
        case .text:
            return merged.filter { $0.contentType == .plainText || $0.contentType == .richText }
        case .urls:
            return merged.filter { $0.contentType == .url }
        case .images:
            return merged.filter { $0.contentType == .image }
        case .developer:
            return merged.filter(\.isDeveloperContent)
        }
    }

    private var displayedItems: [ClipboardItem] {
        let base = items(for: selectedCategory)
        guard !searchQuery.isEmpty else { return base }
        return base.filter { $0.preview.localizedCaseInsensitiveContains(searchQuery) }
    }

    private var selectedItem: ClipboardItem? {
        guard let id = selectedItemID else { return nil }
        return (manager.pinnedItems + manager.items).first { $0.id == id }
    }
}

// MARK: - Category enum

enum HistoryCategory: Hashable, Identifiable {
    case all
    case pinned
    case text
    case urls
    case images
    case developer

    var id: String {
        switch self {
        case .all: "all"
        case .pinned: "pinned"
        case .text: "text"
        case .urls: "urls"
        case .images: "images"
        case .developer: "developer"
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
        }
    }
}

// MARK: - List row

private struct HistoryItemRow: View {
    let item: ClipboardItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(primaryLabel)
                    .font(.system(
                        size: 12,
                        weight: .semibold,
                        design: item.isDeveloperContent ? .monospaced : .default
                    ))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                if let secondary = secondaryLabel {
                    Text(secondary)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Text(relativeTimeString(for: item.timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    if let app = item.sourceAppName {
                        Text("•")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(app)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var primaryLabel: String {
        switch item.content {
        case .text, .richText:
            item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        case .url:
            item.linkTitle ?? item.preview
        case let .image(_, size):
            "Image — \(Int(size.width))×\(Int(size.height))"
        case let .svg(_, size):
            "SVG — \(Int(size.width))×\(Int(size.height))"
        }
    }

    private var secondaryLabel: String? {
        if case .url = item.content, item.linkTitle != nil {
            return item.preview
        }
        return nil
    }

    @ViewBuilder
    private var icon: some View {
        switch item.content {
        case let .image(data, _):
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: item.contentType.systemImage)
                    .foregroundStyle(.secondary)
            }
        case let .svg(data, _):
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: item.contentType.systemImage)
                    .foregroundStyle(.secondary)
            }
        case .url:
            if let faviconData = item.linkFavicon, let nsImage = NSImage(data: faviconData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
            }
        case .text, .richText:
            Image(systemName: item.isDeveloperContent ? "curlybraces" : item.contentType.systemImage)
                .foregroundStyle(item.isDeveloperContent ? .purple : .secondary)
        }
    }
}

// MARK: - Detail pane view

private struct HistoryDetailView: View {
    @Environment(ClipboardManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    let item: ClipboardItem
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                contentView
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }

            Divider()

            metadataBar
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.contentType.rawValue)
                    .font(.caption)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Text(headerTitle)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
            }

            Spacer()

            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("c", modifiers: [.command])

            Button {
                manager.togglePin(item)
            } label: {
                Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.bordered)
        }
    }

    private var headerTitle: String {
        switch item.content {
        case .url: item.linkTitle ?? item.preview
        case let .image(_, size): "\(Int(size.width))×\(Int(size.height)) image"
        default: "Clipboard entry"
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch item.content {
        case let .text(string):
            Text(string)
                .font(.system(size: 13, design: item.isDeveloperContent ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .richText(_, plain):
            Text(plain)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .url(url):
            VStack(alignment: .leading, spacing: 12) {
                if let title = item.linkTitle {
                    Text(title).font(.headline)
                }
                Link(url.absoluteString, destination: url)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                Button("Open in browser") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.bordered)
            }
        case let .image(data, _):
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
        case let .svg(data, _):
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var metadataBar: some View {
        HStack(spacing: 16) {
            if let app = item.sourceAppName {
                metadataItem(icon: "app", label: app)
            }
            metadataItem(icon: "clock", label: relativeTimeString(for: item.timestamp))
            if item.wasMutated {
                metadataItem(
                    icon: "wand.and.stars",
                    label: item.mutationsApplied.joined(separator: ", ")
                )
            }

            Spacer()

            Button {
                openWindow(value: item.id)
            } label: {
                Label("Sticky Note", systemImage: "note.text")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Open as sticky note")

            Button(role: .destructive) {
                manager.removeItem(item)
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Delete item")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metadataItem(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label).lineLimit(1)
        }
    }
}

// MARK: - Shared formatter helper

/// RelativeDateTimeFormatter is not `Sendable`, so we avoid caching it in a static
/// under Swift 6 strict concurrency. Creating one per call is cheap compared to the
/// cost of rendering the detail pane.
@MainActor
private func relativeTimeString(for date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}
