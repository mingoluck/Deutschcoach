import SwiftUI

/// Debug-only lab screen: shows the database location and content counts.
struct ContentView: View {
    let model: AppModel
    @State private var debugMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.phase {
            case .starting, .importing:
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
            Text(verbatim: "Database").font(.headline)
            Text(model.databasePath ?? "–")
                .font(.caption.monospaced())
                .textSelection(.enabled)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text(verbatim: "")
                    Text(verbatim: "entries").bold()
                    Text(verbatim: "sentences").bold()
                }
                ForEach(model.library.seeds) { seed in
                    GridRow {
                        Text(verbatim: seed.seedId)
                        Text(verbatim: "\(seed.entryCount)").monospacedDigit()
                        Text(verbatim: "\(model.library.progress[seed.seedId]?.total ?? 0)").monospacedDigit()
                    }
                }
                Divider()
                GridRow {
                    Text(verbatim: "practice events")
                    Text(verbatim: "\(model.library.practiceEvents)").monospacedDigit()
                }
                GridRow {
                    Text(verbatim: "sessions")
                    Text(verbatim: "\(model.library.sessions)").monospacedDigit()
                }
            }

            Text(verbatim: "Bundled seeds: \(BundledSeeds.urls().map(\.lastPathComponent).joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)

            #if DEBUG
            HStack {
                Button(String("Load debug seed (A1, 12 sentences)")) {
                    Task {
                        do { try await model.loadDebugSeed(); debugMessage = "Debug seed loaded." }
                        catch { debugMessage = error.localizedDescription }
                    }
                }
                if let debugMessage {
                    Text(verbatim: debugMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            #endif
        }
    }
}
