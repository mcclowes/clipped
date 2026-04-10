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
            // Option-click is macOS's idiomatic "alternate action" — in a clipboard manager
            // that means paste-in-place instead of the default copy-and-close.
            if NSEvent.modifierFlags.contains(.option) {
                manager.copyToClipboard(item)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    manager.simulatePaste()
                }
                onCopy?()
            } else {
                manager.copyToClipboard(item)
                onCopy?()
            }
        }
        .contextMenu { actionMenuContent }
    }

    /// Single source of truth for the item action menu. Used by both the right-click
    /// `contextMenu` and the ellipsis button's SwiftUI `Menu`.
    @ViewBuilder
    private var actionMenuContent: some View {
        Button {
            manager.copyToClipboard(item)
            onCopy?()
        } label: {
            Label("Copy", systemImage: "doc.on.clipboard")
        }

        Button {
            manager.copyToClipboard(item)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                manager.simulatePaste()
            }
            onCopy?()
        } label: {
            Label("Paste directly", systemImage: "arrow.down.doc")
        }

        if case .richText = item.content {
            Button {
                manager.copyToClipboard(item, asPlainText: true)
            } label: {
                Label("Copy as plain text", systemImage: "doc.plaintext")
            }
            Button {
                manager.copyAsMarkdown(item)
            } label: {
                Label("Copy as Markdown", systemImage: "text.document")
            }
        }

        Button {
            manager.pasteMatchingStyle(item)
        } label: {
            Label("Paste and match style", systemImage: "doc.on.doc")
        }

        if case let .url(url) = item.content {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open URL", systemImage: "safari")
            }
        }

        Button {
            openWindow(value: item.id)
        } label: {
            Label("Open as sticky note", systemImage: "note.text")
        }

        if item.plainText != nil, Self.is1PasswordInstalled {
            Button {
                manager.copyToClipboard(item, asPlainText: true)
                Self.open1Password()
            } label: {
                Label("Save to 1Password", systemImage: "lock.shield")
            }
        }

        if item.wasMutated {
            Divider()
            Button {
                manager.restoreOriginal(item)
            } label: {
                Label("Restore original", systemImage: "arrow.uturn.backward")
            }
        }

        Divider()

        Button {
            manager.togglePin(item)
        } label: {
            Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
        }

        Divider()

        Button(role: .destructive) {
            manager.removeItem(item)
        } label: {
            Label("Delete", systemImage: "trash")
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
        item.isSensitive && !isRevealed
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
