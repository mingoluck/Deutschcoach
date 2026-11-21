import SwiftUI

/// Settings › Library (DESIGN.md §6): the imported libraries (§2.5) with the ones practiced
/// checked and their progress, and clearing data (§2.6).
struct LibrarySettingsView: View {
    let model: AppModel

    @State private var isWorking = false
    @State private var confirmation: Confirmation?
    @State private var error: String?

    private enum Confirmation: Identifiable {
        case clearRecords, reset
        var id: Self { self }
    }

    var body: some View {
        Form {
            Section {
                if model.library.seeds.isEmpty {
                    Text("No word list imported.").foregroundStyle(.secondary)
                }
                ForEach(model.library.seeds) { seed in
                    libraryRow(seed)
                }
                ForEach(model.seedFailures) { failure in
                    Label("\(failure.seedId) could not be imported: \(failure.message)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Word Lists")
            } footer: {
                Text("Practice draws from the checked word lists. Changing them starts a new session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Clear Data") {
                HStack {
                    Button("Clear Practice Records…", role: .destructive) { confirmation = .clearRecords }
                    Button("Reset Database…", role: .destructive) { confirmation = .reset }
                    if isWorking { ProgressView().controlSize(.small) }
                }
                .disabled(isWorking)
                Text("A backup of the database is saved before anything is deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .task { try? await model.refreshLibrary() }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { action in
            switch action {
            case .clearRecords:
                Button("Clear Practice Records", role: .destructive) { run(action) }
            case .reset:
                Button("Reset Database", role: .destructive) { run(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            switch action {
            case .clearRecords:
                Text("This deletes \(model.library.practiceEvents) practice records and \(model.library.sessions) sessions, including the history. The word lists stay. A backup is saved first.")
            case .reset:
                Text("This deletes \(model.library.practiceEvents) practice records and all content, then loads the bundled word lists again. A backup is saved first.")
            }
        }
    }

    private var confirmationTitle: LocalizedStringKey {
        confirmation == .reset ? "Reset the database?" : "Clear the practice records?"
    }

    /// One library: checkbox (practiced or not), title, level, progress and import details (§6).
    /// The last checked library cannot be unchecked.
    private func libraryRow(_ seed: SeedImport) -> some View {
        let isOn = model.practiceSeeds.contains(seed.seedId)
        return Toggle(isOn: Binding(
            get: { isOn },
            set: { on in Task { await model.setPracticed(seed.seedId, on) } }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: seed.title)
                    Text(verbatim: seed.level.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                if let progress = model.library.progress[seed.seedId] {
                    HStack(spacing: 10) {
                        LibraryProgressBar(progress: progress).frame(width: 180)
                        MasteredLabel(progress: progress)
                    }
                }
                Text("\(seed.seedId) · v\(seed.version) · \(seed.entryCount) entries · \(seed.sentenceCount) sentences · \(Date(timeIntervalSince1970: TimeInterval(seed.importedAt)), format: .dateTime.year().month().day().hour().minute())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(isOn && model.practiceSeeds.count == 1)
    }

    // MARK: - Actions

    private func run(_ action: Confirmation) {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                error = nil
                switch action {
                case .clearRecords: try await model.clearPracticeRecords()
                case .reset: try await model.resetDatabase()
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
