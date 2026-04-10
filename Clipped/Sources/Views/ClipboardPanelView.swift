import SwiftUI

struct ClipboardPanelView: View {
    /// Max number of non-pinned recent items shown in the quick-access panel.
    /// The full history is reachable via the "See more" button which opens `HistoryWindowView`.
    static let quickAccessLimit = 50

    @Environment(ClipboardManager.self) private var manager
    @Environment(SettingsManager.self) private var settings

    /// Callbacks injected by the composition root so the panel never reaches for globals.
    let onOpenSettings: () -> Void
    let onOpenHistoryWindow: () -> Void
    let onClosePanel: () -> Void

    @State private var showClearConfirmation = false
    @State private var clearedSnapshot: ClipboardManager.ClearedSnapshot?
    @State private var clearedCleanupTask: Task<Void, Never>?
    @State private var selectedIndex: Int?
    @State private var showQuickMenu = false
    @State private var showCopiedToast = false
    @State private var copiedToastToken = 0
    @FocusState private var isSearchFocused: Bool

    /// Recent items trimmed to the quick-access cap. Pinned items are always shown in full.
    private var visibleRecentItems: [ClipboardItem] {
        Array(manager.filteredItems.prefix(Self.quickAccessLimit))
    }

    /// True when the underlying recent-item list has more entries than the quick-access cap.
    private var hasMoreRecentItems: Bool {
        manager.filteredItems.count > Self.quickAccessLimit
    }

    private var allVisibleItems: [ClipboardItem] {
        manager.filteredPinnedItems + visibleRecentItems
    }

    private var visibleFilterCategories: [ClipboardFilter] {
        ClipboardFilter.toggleableCategories.filter { !settings.disabledFilterIDs.contains($0.id) }
    }

    var body: some View {
        Group {
            if showQuickMenu {
                quickMenuView
            } else {
                mainPanelView
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in
            if manager.openedViaHotkey {
                manager.openedViaHotkey = false
                manager.openedWithOption = false
                showQuickMenu = false
            } else {
                // StatusBarController captures the modifier state at click time and sets
                // openedWithOption — reading NSEvent.modifierFlags here is a race, the
                // user will typically have released the key by the time the notification fires.
                showQuickMenu = manager.openedWithOption
                manager.openedWithOption = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            showQuickMenu = false
        }
    }

    private var quickMenuView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clipboard")
                    .foregroundStyle(.secondary)
                Text("Clipped")
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
                    action: openSettings
                )

                quickMenuButton(
                    title: "Quit Clipped",
                    icon: "power",
                    action: {
                        NSApplication.shared.terminate(nil)
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
            SearchBar(
                text: $manager.searchQuery,
                isFocused: $isSearchFocused,
                onArrowUp: { moveSelection(by: -1) },
                onArrowDown: { moveSelection(by: 1) },
                onReturnKey: { copySelectedItem() },
                onEscapeKey: { handleEscape() }
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if !visibleFilterCategories.isEmpty {
                ContentTypeFilterBar(
                    selection: $manager.selectedFilter,
                    visibleCategories: visibleFilterCategories
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider()

            if manager.filteredPinnedItems.isEmpty, manager.filteredItems.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if !manager.filteredPinnedItems.isEmpty {
                                Section {
                                    ForEach(manager.filteredPinnedItems) { item in
                                        ClipboardItemRow(
                                            item: item,
                                            isSelected: indexOf(item) == selectedIndex,
                                            onCopy: { dismissAfterCopy() }
                                        )
                                        .id(item.id)
                                    }
                                } header: {
                                    sectionHeader("Pinned")
                                }
                            }

                            if !visibleRecentItems.isEmpty {
                                Section {
                                    ForEach(visibleRecentItems) { item in
                                        ClipboardItemRow(
                                            item: item,
                                            isSelected: indexOf(item) == selectedIndex,
                                            onCopy: { dismissAfterCopy() }
                                        )
                                        .id(item.id)
                                    }
                                } header: {
                                    if !manager.filteredPinnedItems.isEmpty {
                                        sectionHeader("Recent")
                                    }
                                }
                            }

                            if hasMoreRecentItems {
                                seeMoreButton
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        scrollToSelected(proxy: proxy, index: newIndex)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSPopover.didShowNotification)) { _ in
                        scrollToSelected(proxy: proxy, index: selectedIndex)
                    }
                }
            }

            Divider()

            bottomBar
        }
        .frame(width: StatusBarController.panelWidth, height: StatusBarController.panelHeight)
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            copySelectedItem()
            return selectedIndex != nil ? .handled : .ignored
        }
        .onKeyPress(.escape) {
            handleEscape()
            return .handled
        }
        .onKeyPress(.tab, phases: .down) { keyPress in
            if keyPress.modifiers.contains(.shift) {
                moveSelection(by: -1)
            } else {
                moveSelection(by: 1)
            }
            return .handled
        }
        .onChange(of: manager.searchQuery) {
            selectedIndex = nil
        }
        .onChange(of: settings.disabledFilterIDs) {
            // If the active filter was just hidden, fall back to "All" so the user isn't
            // left with an invisible filter applied.
            if let current = manager.selectedFilter, settings.disabledFilterIDs.contains(current.id) {
                manager.selectedFilter = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didShowNotification)) { _ in
            isSearchFocused = true
        }
        .overlay {
            if showCopiedToast {
                copiedToastView
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
    }

    private var seeMoreButton: some View {
        Button(action: openHistoryWindow) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                Text("See full history (\(manager.filteredItems.count))")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .padding(.horizontal, 4)
        .help("Open the full clipboard history in a window")
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
                performClearAll()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(manager.items.isEmpty)

            if clearedSnapshot != nil {
                Button("Undo") {
                    performUndoClear()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
            }

            Spacer()

            Button(action: openHistoryWindow) {
                Label("Full history", systemImage: "clock.arrow.circlepath")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open the full clipboard history window")

            Button {
                manager.exportItems(allVisibleItems)
            } label: {
                Label("Export visible items", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Export all visible items to clipboard")
            .disabled(allVisibleItems.isEmpty)

            Button(action: openSettings) {
                Label("Settings", systemImage: "gear")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Clipped", systemImage: "power")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Clipped")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func performClearAll() {
        clearedCleanupTask?.cancel()
        clearedSnapshot = manager.clearAll()
        clearedCleanupTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            clearedSnapshot = nil
        }
    }

    private func performUndoClear() {
        clearedCleanupTask?.cancel()
        clearedCleanupTask = nil
        if let snapshot = clearedSnapshot {
            manager.restore(snapshot)
        }
        clearedSnapshot = nil
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

    private func copySelectedItem() {
        if let index = selectedIndex, index < allVisibleItems.count {
            manager.copyToClipboard(allVisibleItems[index])
            dismissAfterCopy()
        }
    }

    private func handleEscape() {
        if selectedIndex != nil {
            selectedIndex = nil
        } else if !manager.searchQuery.isEmpty {
            manager.searchQuery = ""
        } else {
            dismissPanel()
        }
    }

    private func moveSelection(by delta: Int) {
        let count = allVisibleItems.count
        guard count > 0 else { return }

        if let current = selectedIndex {
            let next = current + delta
            if next >= 0, next < count {
                selectedIndex = next
            }
        } else {
            selectedIndex = delta > 0 ? 0 : count - 1
        }
    }

    private func scrollToSelected(proxy: ScrollViewProxy, index: Int?) {
        guard let index, index >= 0, index < allVisibleItems.count else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(allVisibleItems[index].id, anchor: .center)
        }
    }

    private func indexOf(_ item: ClipboardItem) -> Int? {
        allVisibleItems.firstIndex(where: { $0.id == item.id })
    }

    private var copiedToastView: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Copied")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            Spacer()
        }
    }

    private func dismissAfterCopy() {
        copiedToastToken &+= 1
        let token = copiedToastToken
        withAnimation(.easeIn(duration: 0.15)) {
            showCopiedToast = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            // Only dismiss if we're still the current toast; rapid copies must not
            // race each other.
            guard token == copiedToastToken else { return }
            showCopiedToast = false
            dismissPanel()
        }
    }

    private func dismissPanel() {
        onClosePanel()
    }

    private func openSettings() {
        onOpenSettings()
    }

    private func openHistoryWindow() {
        onClosePanel()
        onOpenHistoryWindow()
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
