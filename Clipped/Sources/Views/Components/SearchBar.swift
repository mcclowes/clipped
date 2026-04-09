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
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            TextField("Search clipboard...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
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
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5))
        .clipShape(.rect(cornerRadius: 8))
    }
}
