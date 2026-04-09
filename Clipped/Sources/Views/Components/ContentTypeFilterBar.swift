import SwiftUI

struct ContentTypeFilterBar: View {
    @Binding var selection: ClipboardFilter?

    var body: some View {
        HStack(spacing: 4) {
            filterButton(label: "All", filter: nil)

            filterButton(label: "Dev", filter: .developer)

            ForEach(ContentType.allCases) { type in
                filterButton(label: type.rawValue, filter: .contentType(type))
            }
        }
    }

    private func filterButton(label: String, filter: ClipboardFilter?) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selection = filter
            }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: selection == filter ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(selection == filter ? Color.accentColor.opacity(0.15) : .clear)
                .clipShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

extension ContentType: Equatable {}
