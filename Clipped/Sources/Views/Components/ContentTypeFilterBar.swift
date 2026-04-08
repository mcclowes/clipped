import SwiftUI

struct ContentTypeFilterBar: View {
    @Binding var selection: ContentType?

    var body: some View {
        HStack(spacing: 4) {
            filterButton(label: "All", type: nil)

            ForEach(ContentType.allCases) { type in
                filterButton(label: type.rawValue, type: type)
            }
        }
    }

    private func filterButton(label: String, type: ContentType?) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selection = type
            }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: selection == type ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(selection == type ? Color.accentColor.opacity(0.15) : .clear)
                .clipShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

extension ContentType: Equatable {}
