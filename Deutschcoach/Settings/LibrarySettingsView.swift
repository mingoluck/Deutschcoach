import SwiftUI
import UniformTypeIdentifiers

/// Settings › Library (DESIGN.md §6): what the database holds, importing seed files (§2.5),
/// and clearing data (§2.6).
struct LibrarySettingsView: View {
    let model: AppModel

    @State private var isPickingFiles = false
    @State private var preview: SeedImporter.Preview?
    @State private var isWorking = false
    @State private var confirmation: Confirmation?
    @State private var imported: SeedImporter.Report?
    @State private var error: String?

    private enum Confirmation: Identifiable {
        case clearRecords, reset
        var id: Self { self }
    }

    var body: some View {
        Form {
            Section("Active Elements") {
                countsGrid
            }

            Section("Imported Seeds") {
                if model.library.seeds.isEmpty {
                    Text("No seed imported yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.library.seeds) { seed in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: seed.title)
                            Text("\(seed.seedId) · v\(seed.version) · \(seed.elementCount) elements · \(Date(timeIntervalSince1970: TimeInterval(seed.importedAt)), format: .dateTime.year().month().day().hour().minute())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Import Seeds…") { isPickingFiles = true }
                        .disabled(isWorking)
                    if isWorking { ProgressView().controlSize(.small) }
                }
                if let report = imported {
                    Text("Imported \(report.files) files: \(report.elements) elements, \(report.wordForms) word forms, \(report.links) links.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Clear Data") {
                HStack {
                    Button("Clear Practice Records…", role: .destructive) { confirmation = .clearRecords }
                    Button("Reset Database…", role: .destructive) { confirmation = .reset }
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
        .fileImporter(isPresented: $isPickingFiles, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls) where !urls.isEmpty:
                Task { await makePreview(urls) }
            case .success:
                break
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
        .sheet(item: $preview) { preview in
            ImportPreviewSheet(preview: preview) {
                self.preview = nil
                Task { await runImport(preview) }
            } onCancel: {
                self.preview = nil
            }
        }
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
                Text("This deletes \(model.library.practiceEvents) practice records and \(model.library.batches) batches, including the history. The elements stay. A backup is saved first.")
            case .reset:
                Text("This deletes all \(model.library.totalElements) elements and \(model.library.practiceEvents) practice records. Afterwards, import seeds again. A backup is saved first.")
            }
        }
    }

    private var confirmationTitle: LocalizedStringKey {
        confirmation == .reset ? "Reset the database?" : "Clear the practice records?"
    }

    private var countsGrid: some View {
        Grid(alignment: .trailing, horizontalSpacing: 20, verticalSpacing: 6) {
            GridRow {
                Text(verbatim: "")
                ForEach(CEFRLevel.allCases, id: \.self) { level in
                    Text(verbatim: level.rawValue).bold()
                }
            }
            ForEach(ElementKind.allCases, id: \.self) { kind in
                GridRow {
                    Text(kind.displayName).gridColumnAlignment(.leading)
                    ForEach(CEFRLevel.allCases, id: \.self) { level in
                        Text("\(model.library.activeCount(kind, level))").monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func makePreview(_ urls: [URL]) async {
        isWorking = true
        defer { isWorking = false }
        do {
            error = nil
            imported = nil
            preview = try await model.previewImport(of: urls)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runImport(_ preview: SeedImporter.Preview) async {
        isWorking = true
        defer { isWorking = false }
        do {
            error = nil
            try await model.importSeeds(preview)
            imported = model.lastImport
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(_ action: Confirmation) {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                error = nil
                imported = nil
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

extension SeedImporter.Preview: Identifiable {
    var id: String { files.map(\.name).joined(separator: "|") + issues.map(\.localizedDescription).joined() }
}

/// §2.5 step 1: what the import would do, and the issues that block it.
private struct ImportPreviewSheet: View {
    let preview: SeedImporter.Preview
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Seeds").font(.title2.bold())

            List {
                Section("Files") {
                    ForEach(preview.files) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: file.name).bold()
                            if let header = file.header {
                                Text(verbatim: "\(header.title) · \(header.id) · v\(header.version)")
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(file.elements) elements: \(file.new) new, \(file.updated) updated")
                                .font(.caption)
                        }
                    }
                }
                if !preview.issues.isEmpty {
                    Section("Problems") {
                        ForEach(preview.issues, id: \.self) { issue in
                            Label(issue.localizedDescription, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            if !preview.issues.isEmpty {
                Text("Fix the problems in the files and pick them again. Nothing has been imported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: onImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!preview.canImport)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }
}

extension ElementKind {
    var displayName: LocalizedStringKey {
        switch self {
        case .vocab: "Vocabulary"
        case .grammar: "Grammar"
        case .pattern: "Patterns"
        }
    }
}
