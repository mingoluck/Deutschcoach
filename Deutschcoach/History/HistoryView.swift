import SwiftUI

/// The history screen (DESIGN.md §6): the most recent finished sessions, read-only. Checked
/// sentences can be practiced again in a sheet that leaves no trace (§3.6).
struct HistoryView: View {
    @Bindable var history: HistoryModel
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
                VStack(spacing: 0) {
                    selectionBar
                    Divider()
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
        }
        .task { await history.reload() }
        .sheet(isPresented: replayPresented) {
            if let engine = history.replay {
                PracticeContent(engine: engine, language: language) { history.endReplay() }
                    .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 600)
            }
        }
    }

    private var replayPresented: Binding<Bool> {
        Binding(
            get: { history.replay != nil },
            set: { if !$0 { history.endReplay() } }
        )
    }

    private func binding(for id: Int64) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isExpanded in
                if isExpanded { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    // MARK: - Selection (§3.6)

    private var selectionBar: some View {
        let count = history.selectedItems.count
        return HStack(spacing: 12) {
            Text("\(count) selected")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Clear") { history.selection.removeAll() }
                .disabled(count == 0)
            Button("Select Mistakes", systemImage: "xmark.circle") { history.selectMistakes() }
                .disabled(history.mistakes.isEmpty)
            Spacer()
            Button("Practice Again", systemImage: "arrow.counterclockwise") {
                Task { await history.startReplay() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(count == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func isSelected(_ key: HistoryItem.Key) -> Binding<Bool> {
        Binding(
            get: { history.selection.contains(key) },
            set: { isOn in
                if isOn { history.selection.insert(key) } else { history.selection.remove(key) }
            }
        )
    }

    private func allSelected(_ session: HistorySession) -> Binding<Bool> {
        let keys = session.items.map(\.id)
        return Binding(
            get: { !keys.isEmpty && keys.allSatisfy(history.selection.contains) },
            set: { isOn in
                if isOn { history.selection.formUnion(keys) } else { history.selection.subtract(keys) }
            }
        )
    }

    // MARK: - Sessions

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
            Text(verbatim: session.libraries.joined(separator: ", "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("\(session.passed) / \(session.items.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func content(_ session: HistorySession) -> some View {
        let labels = LabelCatalog(language: language)
        Toggle("Select All", isOn: allSelected(session))
            .toggleStyle(.checkbox)
            .padding(.vertical, 4)
        ForEach(session.items) { item in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Toggle(isOn: isSelected(item.id)) {
                        Text("\(item.position)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    Text(item.mode.displayName).font(.caption).foregroundStyle(.secondary)
                }
                RegionalTag(entries: item.regional, showsHeadwords: true)
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
