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
            if NSEvent.modifierFlags.contains(.option) {
                showNSActionMenu()
            } else {
                manager.copyToClipboard(item)
                onCopy?()
            }
        }
        .contextMenu {
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

            Button("Remove", role: .destructive) {
                manager.removeItem(item)
            }
        }
    }

    private func showNSActionMenu() {
        let menu = NSMenu()

        // Metadata section
        if let appName = item.sourceAppName {
            let appItem = NSMenuItem(title: "From: \(appName)", action: nil, keyEquivalent: "")
            appItem.isEnabled = false
            menu.addItem(appItem)
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let timeAgo = formatter.localizedString(for: item.timestamp, relativeTo: Date())
        let timeItem = NSMenuItem(title: "Copied \(timeAgo)", action: nil, keyEquivalent: "")
        timeItem.isEnabled = false
        menu.addItem(timeItem)

        menu.addItem(.separator())

        let pasteItem = NSMenuItem(
            title: "Paste directly",
            action: #selector(ActionMenuTarget.pasteDirectly),
            keyEquivalent: ""
        )
        pasteItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)

        let plainTextItem = NSMenuItem(
            title: "Copy as plain text",
            action: #selector(ActionMenuTarget.copyAsPlainText),
            keyEquivalent: ""
        )
        plainTextItem.image = NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: nil)

        let target = ActionMenuTarget(manager: manager, item: item, openWindow: openWindow)
        pasteItem.target = target
        plainTextItem.target = target
        menu.addItem(pasteItem)
        menu.addItem(plainTextItem)

        if case .richText = item.content {
            let mdItem = NSMenuItem(
                title: "Copy as Markdown",
                action: #selector(ActionMenuTarget.copyAsMarkdown),
                keyEquivalent: ""
            )
            mdItem.image = NSImage(systemSymbolName: "text.document", accessibilityDescription: nil)
            mdItem.target = target
            menu.addItem(mdItem)
        }

        if case let .url(url) = item.content {
            let urlItem = NSMenuItem(title: "Open URL", action: #selector(ActionMenuTarget.openURL), keyEquivalent: "")
            urlItem.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
            urlItem.target = target
            urlItem.representedObject = url
            menu.addItem(urlItem)
        }

        let stickyItem = NSMenuItem(
            title: "Open as sticky note",
            action: #selector(ActionMenuTarget.openStickyNote),
            keyEquivalent: ""
        )
        stickyItem.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
        stickyItem.target = target
        menu.addItem(stickyItem)

        if item.plainText != nil && Self.is1PasswordInstalled {
            let onePassItem = NSMenuItem(
                title: "Save to 1Password",
                action: #selector(ActionMenuTarget.saveTo1Password),
                keyEquivalent: ""
            )
            onePassItem.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
            onePassItem.target = target
            menu.addItem(onePassItem)
        }

        if item.wasMutated {
            menu.addItem(.separator())
            let restoreItem = NSMenuItem(
                title: "Restore original",
                action: #selector(ActionMenuTarget.restoreOriginal),
                keyEquivalent: ""
            )
            restoreItem.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
            restoreItem.target = target
            menu.addItem(restoreItem)
        }

        menu.addItem(.separator())

        let pinTitle = item.isPinned ? "Unpin" : "Pin"
        let pinIcon = item.isPinned ? "pin.slash" : "pin"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(ActionMenuTarget.togglePin), keyEquivalent: "")
        pinItem.image = NSImage(systemSymbolName: pinIcon, accessibilityDescription: nil)
        pinItem.target = target
        menu.addItem(pinItem)

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(ActionMenuTarget.deleteItem), keyEquivalent: "")
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        deleteItem.target = target
        menu.addItem(deleteItem)

        // Keep target alive while menu is open
        objc_setAssociatedObject(menu, "target", target, .OBJC_ASSOCIATION_RETAIN)

        guard let event = NSApp.currentEvent,
              let contentView = event.window?.contentView else { return }
        let point = contentView.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: point, in: contentView)
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
        Button {
            showNSActionMenu()
        } label: {
            Label("More actions", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Actions")
        // Keep the button in the hit-testing / a11y tree even when not visible so
        // keyboard and VoiceOver users can reach it.
        .opacity(isHovered || isSelected ? 1 : 0.01)
        .accessibilityLabel("Actions for clipboard item")
    }
}

@MainActor
private final class ActionMenuTarget: NSObject {
    let manager: ClipboardManager
    let item: ClipboardItem
    let openWindow: OpenWindowAction

    init(manager: ClipboardManager, item: ClipboardItem, openWindow: OpenWindowAction) {
        self.manager = manager
        self.item = item
        self.openWindow = openWindow
    }

    @objc func pasteDirectly() {
        manager.copyToClipboard(item)
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            manager.simulatePaste()
        }
    }

    @objc func copyAsPlainText() {
        manager.copyToClipboard(item, asPlainText: true)
    }

    @objc func copyAsMarkdown() {
        manager.copyAsMarkdown(item)
    }

    @objc func openURL() {
        if case let .url(url) = item.content {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openStickyNote() {
        openWindow(value: item.id)
    }

    @objc func togglePin() {
        manager.togglePin(item)
    }

    @objc func saveTo1Password() {
        manager.copyToClipboard(item, asPlainText: true)
        ClipboardItemRow.open1Password()
    }

    @objc func restoreOriginal() {
        manager.restoreOriginal(item)
    }

    @objc func deleteItem() {
        manager.removeItem(item)
    }
}
