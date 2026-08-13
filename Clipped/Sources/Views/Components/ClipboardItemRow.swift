import SwiftUI

struct ClipboardItemRow: View {
    @Environment(ClipboardManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    let item: ClipboardItem
    var isSelected: Bool = false
    var onCopy: (@MainActor @Sendable () -> Void)?

    @State private var isHovered = false
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 10) {
            contentTypeIcon
            contentPreview
            Spacer(minLength: 4)
            if item.wasMutated {
                Image(systemName: "wand.and.stars")
                    .font(.caption2)
                    .foregroundStyle(.purple.opacity(0.7))
                    .help(item.mutationsApplied.joined(separator: ", "))
            }
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
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
                manager.copyToClipboard(item, completion: onCopy)
            }
        }
        .contextMenu {
            actionMenuContent
        }
        // The row's primary action is a tap gesture, which is invisible to VoiceOver and
        // keyboard focus — expose it as an activatable button. The ellipsis Menu stays a
        // separate accessible element.
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            manager.copyToClipboard(item, completion: onCopy)
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

        if item.availableRepresentations.count > 1 {
            Menu("Copy as…") {
                ForEach(item.availableRepresentations) { representation in
                    Button(representation.title) {
                        manager.copyToClipboard(item, as: representation)
                    }
                }
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

        Divider()

        Menu("Save as…") {
            ForEach(FileExporter.availableFormats(for: item), id: \.self) { format in
                Button(format.title) { presentSavePanel(format: format) }
            }
        }

        if case .image = item.content {
            if let text = item.extractedText {
                Button("Copy extracted text") {
                    manager.copyText(text)
                }
            }
        }

        if case .image = item.content {
            Button("Compress") {
                Task { await manager.compressImage(item) }
            }
            Menu("Convert to") {
                ForEach(RasterImageFormat.allCases, id: \.self) { format in
                    Button(format.displayName) { Task { await manager.convertImage(item, to: format) } }
                }
            }
            Menu("Resize") {
                Button("75%") { Task { await manager.resizeImage(item, scale: 0.75) } }
                Button("50%") { Task { await manager.resizeImage(item, scale: 0.5) } }
                Button("25%") { Task { await manager.resizeImage(item, scale: 0.25) } }
            }
        }

        Divider()

        Button("Open as sticky note") {
            openWindow(value: item.id)
        }

        if item.plainText != nil, Self.is1PasswordInstalled {
            Button("Save to 1Password") {
                manager.copyToClipboard(item, asPlainText: true) {
                    Self.open1Password()
                }
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

    /// Dismiss the panel so focus can return to the previously-active app, then copy and
    /// paste into it. The manager reactivates that app before synthesising Cmd+V.
    private func pasteDirectly() {
        onCopy?()
        manager.pasteToActiveApp(item)
    }

    /// Present the native macOS save panel for a chosen export format, then write the
    /// derived bytes to the picked location. Encoding happens after the user confirms so
    /// cancelling costs nothing.
    private func presentSavePanel(format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(FileExporter.suggestedBaseName(for: item)).\(format.fileExtension)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let data = manager.exportData(for: item, format: format) else {
                NSSound.beep()
                return
            }
            do {
                try data.write(to: url)
            } catch {
                NSSound.beep()
            }
        }
    }

    private var contentTypeIcon: some View {
        Group {
            if shouldMask {
                Image(systemName: "lock.fill")
                    .font(.callout)
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20)
    }

    private var shouldMask: Bool {
        (item.isSensitive || item.containsSecret) && !isRevealed
    }

    private func reveal() {
        manager.reveal(item) { isRevealed = true }
    }

    @ViewBuilder
    private var contentPreview: some View {
        if shouldMask {
            HStack(spacing: 6) {
                Text("••••••••")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Hidden sensitive content")
                Button {
                    reveal()
                } label: {
                    Label("Reveal", systemImage: "eye")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal sensitive content")
                .accessibilityLabel("Reveal sensitive content")
            }
        } else {
            switch item.content {
            case let .image(data, _):
                // Downsampled + cached by item id so scrolling doesn't re-decode the full image.
                if let nsImage = ThumbnailCache.shared.thumbnail(for: item.id, data: data, maxPixel: 96) {
                    HStack(spacing: 8) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 48)
                            .clipShape(.rect(cornerRadius: 4))
                        if let text = item.extractedText {
                            Text(text)
                                .font(.caption)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        }
                    }
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
                            .font(.system(.caption2, design: .monospaced, weight: .semibold))
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
                            .font(.system(.subheadline, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    }
                    Text(item.preview)
                        .font(item.linkTitle != nil ? .caption : .subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.blue)
                }
            case .text, .richText:
                HStack(spacing: 6) {
                    if item.isDeveloperContent {
                        Text(item.preview)
                            .font(.system(.subheadline, design: .monospaced))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    } else {
                        Text(item.preview)
                            .font(.subheadline)
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
                .font(.callout)
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
