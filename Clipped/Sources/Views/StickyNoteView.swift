import SwiftUI

struct StickyNoteView: View {
    @Environment(ClipboardManager.self) private var manager
    @Environment(\.dismissWindow) private var dismissWindow
    let itemID: UUID

    private var item: ClipboardItem? {
        manager.items.first { $0.id == itemID }
    }

    var body: some View {
        Group {
            if let item {
                stickyContent(for: item)
            } else {
                VStack(spacing: 8) {
                    Text("Item no longer available")
                        .foregroundStyle(.secondary)

                    Button("Close") {
                        dismissWindow(value: itemID)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
                .frame(width: 240, height: 80)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 12))
        .floatingPanel()
        .onChange(of: manager.items.contains { $0.id == itemID }) { _, exists in
            if !exists {
                dismissWindow(value: itemID)
            }
        }
    }

    private func stickyContent(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            dragBar(for: item)

            ScrollView {
                contentBody(for: item)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 200, idealWidth: 300, minHeight: 100, idealHeight: 200)
    }

    private func dragBar(for item: ClipboardItem) -> some View {
        HStack {
            Image(systemName: item.contentType.systemImage)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Text(item.contentType.rawValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                manager.copyToClipboard(item)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                dismissWindow(value: item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func contentBody(for item: ClipboardItem) -> some View {
        switch item.content {
        case let .text(string):
            selectableText(string, isCode: item.contentType == .code)

        case let .richText(_, plainText):
            selectableText(plainText, isCode: false)

        case let .url(url):
            VStack(alignment: .leading, spacing: 4) {
                if let title = item.linkTitle {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                }
                Text(url.absoluteString)
                    .font(.system(size: 12))
                    .foregroundStyle(.blue)
            }

        case let .image(data, _):
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 6))
            }
        }
    }

    private func selectableText(_ string: String, isCode: Bool) -> some View {
        Text(string)
            .font(.system(size: 12, design: isCode ? .monospaced : .default))
            .textSelection(.enabled)
    }
}
