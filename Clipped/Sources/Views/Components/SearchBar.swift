import SwiftUI

struct SearchBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onReturnKey: (() -> Void)?
    var onEscapeKey: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.tertiary)

            TextField("Search clipboard...", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused(isFocused)
                .onKeyPress(.upArrow) {
                    onArrowUp?()
                    return onArrowUp != nil ? .handled : .ignored
                }
                .onKeyPress(.downArrow) {
                    onArrowDown?()
                    return onArrowDown != nil ? .handled : .ignored
                }
                .onKeyPress(.return) {
                    onReturnKey?()
                    return onReturnKey != nil ? .handled : .ignored
                }
                .onKeyPress(.escape) {
                    onEscapeKey?()
                    return onEscapeKey != nil ? .handled : .ignored
                }
                .onKeyPress(.tab, phases: .down) { keyPress in
                    if keyPress.modifiers.contains(.shift) {
                        onArrowUp?()
                        return onArrowUp != nil ? .handled : .ignored
                    } else {
                        onArrowDown?()
                        return onArrowDown != nil ? .handled : .ignored
                    }
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5))
        .clipShape(.rect(cornerRadius: 8))
    }
}
