import SwiftUI

/// Temporary M1 debug screen: shows the database location and content counts.
/// Replaced by the practice screen in later milestones.
struct ContentView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.phase {
            case .starting:
                ProgressView("Opening database…")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            case .ready:
                readyView
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 300, alignment: .topLeading)
    }

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Database").font(.headline)
            Text(model.databasePath ?? "–")
                .font(.caption.monospaced())
                .textSelection(.enabled)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                ForEach(ElementKind.allCases, id: \.self) { kind in
                    GridRow {
                        Text(kind.rawValue)
                        Text("\(model.summary.elementsByKind[kind] ?? 0)").monospacedDigit()
                    }
                }
                Divider()
                GridRow {
                    Text("elements").bold()
                    Text("\(model.summary.totalElements)").monospacedDigit().bold()
                }
                GridRow {
                    Text("word forms")
                    Text("\(model.summary.wordForms)").monospacedDigit()
                }
                GridRow {
                    Text("links")
                    Text("\(model.summary.links)").monospacedDigit()
                }
            }

            HStack {
                Button("Re-import Seed") {
                    Task { await model.reimportSeed() }
                }
                if let report = model.lastImport {
                    Text("Last import: \(report.elements) elements, \(report.wordForms) forms, \(report.links) links")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
