import SwiftUI

/// Popover content for an on-device summarization run, triggered from a history
/// row's context menu. Renders three states: in-flight, a finished summary, or a
/// failure message. See `Summarizer` and issue #73.
struct SummaryPopover: View {
    /// The lifecycle of one summarization request.
    enum Phase: Equatable {
        case loading
        case result(String)
        case failure(String)
    }

    let phase: Phase
    /// Invoked with the summary text when the user chooses to keep it.
    let onCopy: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            Text("Summary")
                .font(.headline)
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Summarizing on-device\u{2026}")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case let .result(summary):
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    Text(summary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)

                HStack {
                    Spacer()
                    Button("Dismiss", action: onDismiss)
                    Button("Copy Summary") { onCopy(summary) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }

        case let .failure(message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Spacer()
                    Button("Dismiss", action: onDismiss)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
