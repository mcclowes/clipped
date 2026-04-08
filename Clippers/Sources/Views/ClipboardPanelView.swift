import SwiftUI

struct ClipboardPanelView: View {
    @Environment(ClipboardManager.self) private var manager
    @Binding var showOnboarding: Bool
    @State private var showClearConfirmation = false
    @State private var recentlyClearedItems: [ClipboardItem]?
    @State private var selectedIndex: Int?
    @State private var showQuickMenu = false

    private var allVisibleItems: [ClipboardItem] {
        manager.pinnedItems + manager.filteredItems
    }

    var body: some View {
        Group {
            if showQuickMenu {
                quickMenuView
            } else {
                mainPanelView
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window is NSPanel,
                  window.className.contains("StatusBarWindow") || window.className.contains("MenuBarExtra")
            else { return }

            if manager.openedViaHotkey {
                manager.openedViaHotkey = false
                showQuickMenu = false
            } else {
                showQuickMenu = NSEvent.modifierFlags.contains(.option)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window is NSPanel,
                  window.className.contains("StatusBarWindow") || window.className.contains("MenuBarExtra")
            else { return }

            showQuickMenu = false
            dismissPanel()
        }
    }

    private var quickMenuView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clipboard")
                    .foregroundStyle(.secondary)
                Text("Clippers")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            VStack(spacing: 2) {
                quickMenuButton(
                    title: manager.isMonitoring ? "Pause monitoring" : "Resume monitoring",
                    icon: manager.isMonitoring ? "pause.circle" : "play.circle",
                    action: {
                        if manager.isMonitoring {
                            manager.stopMonitoring()
                        } else {
                            manager.startMonitoring()
                        }
                    }
                )

                quickMenuButton(
                    title: "Clear history",
                    icon: "trash",
                    action: {
                        manager.clearAll()
                    }
                )

                Divider()
                    .padding(.vertical, 4)

                quickMenuButton(
                    title: "Settings...",
                    icon: "gear",
                    action: {
                        NSApp.activate()
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                )
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
        .frame(width: 220)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func quickMenuButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.0001), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuickMenuButtonStyle())
    }

    private var mainPanelView: some View {
        @Bindable var manager = manager

        return VStack(spacing: 0) {
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
                                    ClipboardItemRow(
                                        item: item,
                                        isSelected: indexOf(item) == selectedIndex
                                    )
                                }
                            } header: {
                                sectionHeader("Pinned")
                            }
                        }

                        if !manager.filteredItems.isEmpty {
                            Section {
                                ForEach(manager.filteredItems) { item in
                                    ClipboardItemRow(
                                        item: item,
                                        isSelected: indexOf(item) == selectedIndex
                                    )
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
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            if let index = selectedIndex, index < allVisibleItems.count {
                manager.copyToClipboard(allVisibleItems[index])
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            if selectedIndex != nil {
                selectedIndex = nil
                return .handled
            }
            if !manager.searchQuery.isEmpty {
                manager.searchQuery = ""
                return .handled
            }
            dismissPanel()
            return .handled
        }
        .onChange(of: manager.searchQuery) {
            selectedIndex = nil
        }
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

    private func moveSelection(by delta: Int) {
        let count = allVisibleItems.count
        guard count > 0 else { return }

        if let current = selectedIndex {
            let next = current + delta
            if next >= 0 && next < count {
                selectedIndex = next
            }
        } else {
            selectedIndex = delta > 0 ? 0 : count - 1
        }
    }

    private func indexOf(_ item: ClipboardItem) -> Int? {
        allVisibleItems.firstIndex(where: { $0.id == item.id })
    }

    private func dismissPanel() {
        if let panel = NSApp.windows.first(where: {
            $0 is NSPanel && $0.className.contains("StatusBarWindow")
                || $0.className.contains("MenuBarExtra")
        }) {
            panel.orderOut(nil)
        }
    }
}

private struct QuickMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? AnyShapeStyle(.primary.opacity(0.1)) : AnyShapeStyle(.clear))
            )
    }
}
