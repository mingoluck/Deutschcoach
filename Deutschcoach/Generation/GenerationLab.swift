import Foundation
import GRDB
import Observation

/// Drives the temporary M4 generation screen: API key, "generate a batch", and the latest batch.
@Observable
final class GenerationLab {
    struct DisplaySentence: Identifiable {
        var id: Int64
        var position: Int
        var mode: SentenceMode
        var de: String
        var translation: String
        var annotation: SentenceAnnotation?
        var targets: [String]
        var incidental: [String]
    }

    var keyInput = ""
    private(set) var hasKey = false
    private(set) var isGenerating = false
    private(set) var log: [String] = []
    private(set) var report: BatchGenerator.Report?
    private(set) var sentences: [DisplaySentence] = []
    private(set) var batchCount = 0
    private(set) var errorMessage: String?

    private let keychain = KeychainStore.apiKey

    // MARK: - API key

    func refreshKeyState() {
        hasKey = ((try? keychain.read()) ?? nil)?.isEmpty == false
    }

    func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try keychain.save(key)
            keyInput = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshKeyState()
    }

    func deleteKey() {
        do {
            try keychain.delete()
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshKeyState()
    }

    // MARK: - Generation

    func generate(database: AppDatabase) async {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        report = nil
        log = []
        defer { isGenerating = false }

        let keychain = self.keychain
        let model = ClaudeLanguageModel(client: ClaudeClient(apiKey: { try keychain.read() }))
        let generator = BatchGenerator(database: database, model: model)
        do {
            let request = try await database.writer.read { db in try ElementPicker().makeRequest(from: db) }
            append("Requesting \(request.sentences.count) sentences from \(model.modelName)…")
            let report = try await generator.generate(request) { [weak self] event in
                Task { @MainActor in self?.append(Self.describe(event)) }
            }
            self.report = report
            append("Stored \(report.storedPositions.count) sentences in batch #\(report.batchId) after \(report.rounds) round(s).")
            await loadLatest(database: database)
        } catch {
            errorMessage = error.localizedDescription
            append("Failed: \(error.localizedDescription)")
        }
    }

    func loadLatest(database: AppDatabase) async {
        do {
            let language = NativeLanguage.current
            let (count, rows) = try await database.writer.read { db -> (Int, [DisplaySentence]) in
                let count = try Batch.fetchCount(db)
                guard let batchId = try Int64.fetchOne(db, sql: "SELECT id FROM batch ORDER BY id DESC LIMIT 1") else {
                    return (count, [])
                }
                let sentences = try Sentence.fetchAll(db, sql: "SELECT * FROM sentence WHERE batch_id = ? ORDER BY position", arguments: [batchId])
                let rows = try sentences.map { sentence in
                    let titles = { (role: String) in
                        try String.fetchAll(db, sql: """
                            SELECT e.title FROM sentence_element se JOIN element e ON e.id = se.element_id
                            WHERE se.sentence_id = ? AND se.role = ? ORDER BY e.kind, e.title
                            """, arguments: [sentence.id, role])
                    }
                    return DisplaySentence(
                        id: sentence.id!,
                        position: sentence.position,
                        mode: sentence.mode,
                        de: sentence.de,
                        translation: sentence.translation(for: language) ?? "",
                        annotation: try? sentence.decodedAnnotation(),
                        targets: try titles("target"),
                        incidental: try titles("incidental")
                    )
                }
                return (count, rows)
            }
            batchCount = count
            sentences = rows
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private

    private func append(_ line: String) {
        log.append(line)
    }

    private static func describe(_ event: BatchGenerator.Event) -> String {
        switch event {
        case .requesting(let round, let positions):
            "Round \(round): requesting positions \(positions.map(String.init).joined(separator: ", "))"
        case .accepted(let position):
            "  #\(position) accepted"
        case .rejected(let failure):
            "  #\(failure.position) rejected: \(failure.reason)"
        }
    }

    /// Approximate cost for `claude-haiku-5-5` (prompts ≤ 100K tokens): $0.10 / $0.50 per MTok,
    /// cache writes 1.25× and cache reads 0.1× the input rate.
    static func estimatedCost(_ usage: TokenUsage) -> Double {
        let input = 0.10 / 1_000_000
        let output = 0.50 / 1_000_000
        return Double(usage.input) * input
            + Double(usage.cacheWrite) * input * 1.25
            + Double(usage.cacheRead) * input * 0.1
            + Double(usage.output) * output
    }
}
