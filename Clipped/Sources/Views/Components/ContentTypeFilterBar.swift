import SwiftUI

struct ContentTypeFilterBar: View {
    @Binding var selection: ClipboardFilter?
    /// Ordered list of filter categories to expose as tabs. "All" is always prepended.
    let visibleCategories: [ClipboardFilter]

    var body: some View {
        HStack(spacing: 4) {
            filterButton(label: "All", filter: nil)
            ForEach(visibleCategories) { category in
                filterButton(label: category.label, filter: category)
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
