import SwiftUI

struct ClipboardItemRow: View {
    @Environment(ClipboardManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    let item: ClipboardItem
    var isSelected: Bool = false
    var onCopy: (() -> Void)?

    @State private var isHovered = false
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 10) {
            contentTypeIcon
            contentPreview
            Spacer(minLength: 4)
            if item.wasMutated {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 9))
                    .foregroundStyle(.purple.opacity(0.7))
                    .help(item.mutationsApplied.joined(separator: ", "))
            }
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
            }
            ellipsisButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : isHovered ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .clipShape(.rect(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .onTapGesture {
            // Option-click is the "alt action": paste the item directly without leaving
            // the menu. The unified action menu is reachable via right-click or the
            // ellipsis button — the previous option-click → NSMenu was the dual code
            // path this consolidation removes.
            if NSEvent.modifierFlags.contains(.option) {
                pasteDirectly()
            } else {
                manager.copyToClipboard(item)
                onCopy?()
            }
        }
        .contextMenu {
            actionMenuContent
        }
    }

    /// Single source of truth for the row's action menu, shared by right-click
    /// (`.contextMenu`) and the ellipsis button (`Menu { ... }`). Adding or removing
    /// a menu item now only needs to happen in one place.
    @ViewBuilder
    private var actionMenuContent: some View {
        Button("Copy") {
            manager.copyToClipboard(item)
        }

        if case .richText = item.content {
            Button("Copy as plain text") {
                manager.copyToClipboard(item, asPlainText: true)
            }
            Button("Copy as Markdown") {
                manager.copyAsMarkdown(item)
            }
        }

        Button("Paste and match style") {
            manager.pasteMatchingStyle(item)
        }

        Button("Paste directly") {
            pasteDirectly()
        }

        if case let .url(url) = item.content {
            Button("Open URL") {
                NSWorkspace.shared.open(url)
            }
        }

        Button("Open as sticky note") {
            openWindow(value: item.id)
        }

        if item.plainText != nil, Self.is1PasswordInstalled {
            Button("Save to 1Password") {
                manager.copyToClipboard(item, asPlainText: true)
                Self.open1Password()
            }
        }

        if item.wasMutated {
            Divider()
            Button("Restore original") {
                manager.restoreOriginal(item)
            }
        }

        Divider()

        Button(item.isPinned ? "Unpin" : "Pin") {
            manager.togglePin(item)
        }

        Divider()

        Button("Delete", role: .destructive) {
            manager.removeItem(item)
        }
    }

    /// Copy the item to the pasteboard, then simulate Cmd+V after a short delay so the
    /// target app has time to regain focus. Matches the old NSMenu's "Paste directly"
    /// action.
    private func pasteDirectly() {
        manager.copyToClipboard(item)
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            manager.simulatePaste()
        }
    }

    private var contentTypeIcon: some View {
        Group {
            if shouldMask {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            } else if case .url = item.content,
                      let faviconData = item.linkFavicon,
                      let nsImage = NSImage(data: faviconData)
            {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            } else {
                Image(systemName: item.contentType.systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20)
    }

    private var shouldMask: Bool {
        (item.isSensitive || item.containsSecret) && !isRevealed
    }

    @ViewBuilder
    private var contentPreview: some View {
        if shouldMask {
            HStack(spacing: 6) {
                Text("••••••••")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Hidden sensitive content")
                Button {
                    isRevealed = true
                } label: {
                    Label("Reveal", systemImage: "eye")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal sensitive content")
                .accessibilityLabel("Reveal sensitive content")
            }
        } else {
            switch item.content {
            case let .image(data, _):
                if let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 48)
                        .clipShape(.rect(cornerRadius: 4))
                }
            case let .svg(data, _):
                if let nsImage = NSImage(data: data) {
                    HStack(spacing: 8) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 48)
                            .clipShape(.rect(cornerRadius: 4))
                        Text("SVG")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .foregroundStyle(.secondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(.secondary.opacity(0.35), lineWidth: 0.5)
                            )
                    }
                }
            case .url:
                VStack(alignment: .leading, spacing: 2) {
                    if let title = item.linkTitle {
                        Text(title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    }
                    Text(item.preview)
                        .font(.system(size: item.linkTitle != nil ? 10 : 11))
                        .lineLimit(1)
                        .foregroundStyle(.blue)
                }
            case .text, .richText:
                HStack(spacing: 6) {
                    if item.isDeveloperContent {
                        Text(item.preview)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    } else {
                        Text(item.preview)
                            .font(.system(size: 11))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    }
                    if let color = HexColorParser.firstColor(in: item.preview) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: color))
                            .frame(width: 14, height: 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
                            )
                    }
                }
            }
        }
    }

    private static let onePasswordBundleID = "com.1password.1password"

    static var is1PasswordInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: onePasswordBundleID) != nil
    }

    static func open1Password() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: onePasswordBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private var ellipsisButton: some View {
        Menu {
            actionMenuContent
        } label: {
            Label("More actions", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Actions")
        // Keep the button in the hit-testing / a11y tree even when not visible so
        // keyboard and VoiceOver users can reach it.
        .opacity(isHovered || isSelected ? 1 : 0.01)
        .accessibilityLabel("Actions for clipboard item")
    }
}
