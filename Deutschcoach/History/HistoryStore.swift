import Foundation
import GRDB

/// One answered sentence of a session in the history (DESIGN.md §6).
nonisolated struct HistoryItem: Sendable, Equatable, Identifiable {
    /// Identifies an item across sessions, e.g. for the re-practice selection (§3.6).
    struct Key: Sendable, Hashable {
        var sessionId: Int64
        var position: Int
    }

    var sessionId: Int64
    var position: Int
    var mode: SentenceMode
    var sentence: Sentence
    var annotation: SentenceAnnotation
    /// Austrian or Swiss entries of the sentence (§3.3).
    var regional: [RegionalEntry] = []
    /// The scored answer; nil when the item has no event (e.g. an unanswered item).
    var outcome: ScoredAnswer?

    var id: Key { Key(sessionId: sessionId, position: position) }
}

nonisolated struct HistorySession: Sendable, Equatable, Identifiable {
    var id: Int64
    /// Titles of the libraries the session was picked from.
    var libraries: [String]
    var finishedAt: Date?
    var items: [HistoryItem]

    var passed: Int { items.filter { $0.outcome?.result.outcome == .pass }.count }
}

/// Reads the most recent finished sessions (§2.3: at most 10 are kept).
nonisolated struct HistoryStore: Sendable {
    let database: AppDatabase

    func load() async throws -> [HistorySession] {
        try await database.writer.read { db in
            let titles = Dictionary(uniqueKeysWithValues: try SeedImport.fetchAll(db).map { ($0.seedId, $0.title) })
            let sessions = try Session
                .filter(Column("status") == SessionStatus.done.rawValue)
                .order(Column("finished_at").desc, Column("id").desc)
                .limit(PracticeStore.keptSessions)
                .fetchAll(db)
            return try sessions.map { session in
                let items = try SessionItem.filter(Column("session_id") == session.id).order(Column("position")).fetchAll(db)
                return HistorySession(
                    id: session.id!,
                    libraries: session.seedIds.map { titles[$0] ?? $0 },
                    finishedAt: session.finishedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    items: try items.map { try Self.item($0, db: db) }
                )
            }
        }
    }

    /// §3.6: the items to re-practice, each in its history mode, with cloze blanks as in §3.2.
    func practiceItems(_ items: [HistoryItem]) async throws -> [PracticeItem] {
        try await database.writer.read { db in
            try items.map { item in
                PracticeItem(sessionId: item.sessionId, position: item.position, mode: item.mode,
                             sentence: item.sentence, annotation: item.annotation,
                             blanks: item.mode == .cloze ? try PracticeStore.clozeBlanks(sentenceId: item.sentence.id, db: db) : [],
                             regional: item.regional)
            }
        }
    }

    private static func item(_ item: SessionItem, db: Database) throws -> HistoryItem {
        guard let sentence = try Sentence.fetchOne(db, key: item.sentenceId) else {
            throw DatabaseError(message: "sentence \(item.sentenceId) is missing")
        }
        let event = try PracticeEvent
            .filter(Column("session_id") == item.sessionId && Column("sentence_id") == item.sentenceId)
            .order(Column("id").desc)
            .fetchOne(db)
        let annotation = try sentence.decodedAnnotation()
        var outcome: ScoredAnswer?
        if let event {
            let detail = event.detail.flatMap { try? JSONDecoder().decode(PracticeEventDetail.self, from: Data($0.utf8)) }
            // The comparison is recomputed from the stored transcription, as on the practice screen.
            var result = AnswerMatcher.score(de: sentence.de, spoken: sentence.spoken, heard: detail?.heard,
                                             skipped: detail?.reason == .skipped,
                                             names: annotation.foreignNames)
            result.outcome = event.outcome
            outcome = ScoredAnswer(heard: detail?.heard, result: result)
        }
        return HistoryItem(sessionId: item.sessionId, position: item.position, mode: item.mode, sentence: sentence,
                           annotation: annotation,
                           regional: try RegionalEntry.load(sentenceId: sentence.id, db: db), outcome: outcome)
    }
}
