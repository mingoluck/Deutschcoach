import Foundation
import GRDB

/// One finished sentence as shown in the history (DESIGN.md §6).
nonisolated struct HistorySentence: Sendable, Equatable, Identifiable {
    enum Result: Sendable, Equatable {
        case passed
        case mistakes
        /// Answered, but no element was scored (no speech, unclear, paraphrase only).
        case notScored
        case skipped
    }

    var id: Int64
    var position: Int
    var mode: SentenceMode
    var de: String
    var annotation: SentenceAnnotation?
    /// `nil` when there is no translation in the current native language yet.
    var translation: String?
    var result: Result
}

nonisolated struct HistoryBatch: Sendable, Equatable, Identifiable {
    var id: Int64
    var finishedAt: Date?
    var sentences: [HistorySentence]

    var missingTranslations: Bool { sentences.contains { $0.translation == nil } }
}

/// Reads the history (read-only) and writes on-demand translations back (§3.1).
nonisolated struct HistoryStore: Sendable {
    var database: AppDatabase

    /// `done` batches, most recent first (pruning keeps at most 10, §2.3).
    func load(language: String) async throws -> [HistoryBatch] {
        try await database.writer.read { db in
            let batches = try Batch
                .filter(Column("status") == BatchStatus.done.rawValue)
                .order(Column("finished_at").desc, Column("id").desc)
                .fetchAll(db)
            return try batches.map { batch in
                let sentences = try Sentence
                    .filter(Column("batch_id") == batch.id)
                    .order(Column("position"))
                    .fetchAll(db)
                return HistoryBatch(
                    id: batch.id!,
                    finishedAt: batch.finishedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    sentences: try sentences.map { sentence in
                        HistorySentence(
                            id: sentence.id!,
                            position: sentence.position,
                            mode: sentence.mode,
                            de: sentence.de,
                            annotation: try? sentence.decodedAnnotation(),
                            translation: sentence.translation(for: language),
                            result: try Self.result(of: sentence, db: db)
                        )
                    }
                )
            }
        }
    }

    /// Summarized from the sentence's events.
    static func result(of sentence: Sentence, db: Database) throws -> HistorySentence.Result {
        if sentence.status == .skipped { return .skipped }
        let outcomes = try String.fetchAll(db, sql: "SELECT outcome FROM practice_event WHERE sentence_id = ?", arguments: [sentence.id])
            .compactMap(PracticeOutcome.init(rawValue:))
        if outcomes.contains(.fail) { return .mistakes }
        if outcomes.contains(.pass) { return .passed }
        return .notScored
    }

    /// Asks the model for the missing translations of one batch and stores them.
    func translate(_ batch: HistoryBatch, into language: String, model: any LanguageModel) async throws {
        let missing = batch.sentences.filter { $0.translation == nil }
        guard !missing.isEmpty else { return }
        let request = TranslationRequest(
            nativeLang: language,
            sentences: missing.map { TranslationRequest.Item(id: $0.id, mode: $0.mode, de: $0.de) }
        )
        let translations = try await model.translate(request)
        try await save(translations, language: language)
    }

    /// Merges translations into `sentence.translations`.
    func save(_ translations: [Int64: String], language: String) async throws {
        try await database.writer.write { db in
            for (id, text) in translations {
                try db.execute(
                    sql: "UPDATE sentence SET translations = json_set(translations, '$.' || ?, ?) WHERE id = ?",
                    arguments: [language, text, id]
                )
            }
        }
    }
}
