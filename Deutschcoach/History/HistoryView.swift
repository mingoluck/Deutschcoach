import SwiftUI

/// The history screen (DESIGN.md §6): the most recent finished batches, read-only.
struct HistoryView: View {
    let history: HistoryModel
    @State private var expanded: Set<Int64> = []

    var body: some View {
        Group {
            if let error = history.loadError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if history.batches.isEmpty {
                Text("No finished batches yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(history.batches) { batch in
                        DisclosureGroup(isExpanded: binding(for: batch.id)) {
                            batchContent(batch)
                        } label: {
                            batchLabel(batch)
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
                if isExpanded {
                    expanded.insert(id)
                    Task { await history.translateIfNeeded(id) }
                } else {
                    expanded.remove(id)
                }
            }
        )
    }

    private func batchLabel(_ batch: HistoryBatch) -> some View {
        let passed = batch.sentences.filter { $0.result == .passed }.count
        return HStack {
            Group {
                if let finishedAt = batch.finishedAt {
                    // `Text(_:format:)` formats with the view's locale (the native language).
                    Text(finishedAt, format: .dateTime.year().month().day().hour().minute())
                } else {
                    Text(verbatim: "–")
                }
            }
            .font(.headline)
            Spacer()
            Text("\(passed) / \(batch.sentences.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func batchContent(_ batch: HistoryBatch) -> some View {
        if let error = history.errors[batch.id] {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button("Retry") { Task { await history.translateIfNeeded(batch.id) } }
            }
        }
        ForEach(batch.sentences) { sentence in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("\(sentence.position)").monospacedDigit().foregroundStyle(.secondary)
                    Text(sentence.mode.displayName).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    resultLabel(sentence.result)
                }
                if let annotation = sentence.annotation {
                    AnnotatedSentenceView(annotation)
                } else {
                    Text(sentence.de).font(.title3)
                }
                if let translation = sentence.translation {
                    Text(translation).foregroundStyle(.secondary).textSelection(.enabled)
                } else if history.translating.contains(batch.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Translating…").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func resultLabel(_ result: HistorySentence.Result) -> some View {
        switch result {
        case .passed: Label("Correct", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .mistakes: Label("Mistakes", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .notScored: Label("Not scored", systemImage: "minus.circle").foregroundStyle(.secondary)
        case .skipped: Label("Skipped", systemImage: "forward").foregroundStyle(.secondary)
        }
    }
}
