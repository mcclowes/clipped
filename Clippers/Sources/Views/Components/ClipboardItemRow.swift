import SwiftUI

struct ClipboardItemRow: View {
    @Environment(ClipboardManager.self) private var manager
    let item: ClipboardItem

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            contentTypeIcon
            contentPreview
            Spacer(minLength: 4)
            metadata
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear)
        .clipShape(.rect(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .onTapGesture {
            manager.copyToClipboard(item)
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

            if case .url(let url) = item.content {
                Button("Open URL") {
                    NSWorkspace.shared.open(url)
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

    private var contentTypeIcon: some View {
        Image(systemName: item.contentType.systemImage)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 20)
    }

    @ViewBuilder
    private var contentPreview: some View {
        switch item.content {
        case .image(let data, _):
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
            if item.contentType == .code {
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
        }
    }

    private var metadata: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let appName = item.sourceAppName {
                Text(appName)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Text(item.timestamp, style: .relative)
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
            }
        }
    }
}
