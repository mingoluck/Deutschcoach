import SwiftUI

/// The history screen (DESIGN.md §6): the most recent finished sessions, read-only.
struct HistoryView: View {
    let history: HistoryModel
    let language: String
    @State private var expanded: Set<Int64> = []

    var body: some View {
        Group {
            if let error = history.loadError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if history.sessions.isEmpty {
                Text("No sessions yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(history.sessions) { session in
                        DisclosureGroup(isExpanded: binding(for: session.id)) {
                            content(session)
                        } label: {
                            label(session)
                        }
                    }
                }
            }
        }
        .task { await history.reload() }
    }

    private func binding(for id: Int64) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isExpanded in
                if isExpanded { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    private func label(_ session: HistorySession) -> some View {
        HStack {
            Group {
                if let finishedAt = session.finishedAt {
                    // `Text(_:format:)` formats with the view's locale (the native language).
                    Text(finishedAt, format: .dateTime.year().month().day().hour().minute())
                } else {
                    Text(verbatim: "–")
                }
            }
            .font(.headline)
            Text(verbatim: session.level.rawValue).foregroundStyle(.secondary)
            Spacer()
            Text("\(session.passed) / \(session.items.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func content(_ session: HistorySession) -> some View {
        let labels = LabelCatalog(language: language)
        ForEach(session.items) { item in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("\(item.position)").monospacedDigit().foregroundStyle(.secondary)
                    Text(item.mode.displayName).font(.caption).foregroundStyle(.secondary)
                }
                AnnotatedSentenceView(item.annotation, labels: labels)
                Text(item.sentence.translation(for: language) ?? "")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let outcome = item.outcome {
                    ResultView(outcome: outcome)
                }
            }
            .padding(.vertical, 8)
        }
    }
}
