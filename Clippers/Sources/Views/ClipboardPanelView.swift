import SwiftUI

struct ClipboardPanelView: View {
    @Environment(ClipboardManager.self) private var manager
    @Binding var showOnboarding: Bool
    @State private var showClearConfirmation = false
    @State private var recentlyClearedItems: [ClipboardItem]?

    var body: some View {
        @Bindable var manager = manager

        VStack(spacing: 0) {
            SearchBar(text: $manager.searchQuery)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ContentTypeFilterBar(selection: $manager.selectedContentType)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            if manager.pinnedItems.isEmpty && manager.filteredItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if !manager.pinnedItems.isEmpty {
                            Section {
                                ForEach(manager.pinnedItems) { item in
                                    ClipboardItemRow(item: item)
                                }
                            } header: {
                                sectionHeader("Pinned")
                            }
                        }

                        if !manager.filteredItems.isEmpty {
                            Section {
                                ForEach(manager.filteredItems) { item in
                                    ClipboardItemRow(item: item)
                                }
                            } header: {
                                if !manager.pinnedItems.isEmpty {
                                    sectionHeader("Recent")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }

            Divider()

            bottomBar
        }
        .frame(width: 320, height: 420)
        .overlay {
            if showOnboarding {
                OnboardingOverlay(isPresented: $showOnboarding)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clipboard")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No clipboard items")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Copy something to get started")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var bottomBar: some View {
        HStack {
            Button("Clear All") {
                recentlyClearedItems = manager.items
                manager.clearAll()

                Task {
                    try? await Task.sleep(for: .seconds(3))
                    recentlyClearedItems = nil
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(manager.items.isEmpty)

            if recentlyClearedItems != nil {
                Button("Undo") {
                    if let cleared = recentlyClearedItems {
                        for item in cleared.reversed() {
                            manager.items.append(item)
                        }
                        recentlyClearedItems = nil
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
            }

            Spacer()

            Button {
                let allTextItems = manager.pinnedItems + manager.filteredItems
                manager.exportItems(allTextItems)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Export all visible items to clipboard")
            .disabled(manager.pinnedItems.isEmpty && manager.filteredItems.isEmpty)

            Button {
                NSApp.activate()
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gear")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Clippers")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 6)
    }
}
