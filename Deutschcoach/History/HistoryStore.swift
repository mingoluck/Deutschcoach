import Foundation
import GRDB

/// One answered sentence of a session in the history (DESIGN.md §6).
nonisolated struct HistoryItem: Sendable, Equatable, Identifiable {
    var position: Int
    var mode: SentenceMode
    var sentence: Sentence
    var annotation: SentenceAnnotation
    /// The scored answer; nil when the item has no event (e.g. an unanswered item).
    var outcome: ScoredAnswer?

    var id: Int { position }
}

nonisolated struct HistorySession: Sendable, Equatable, Identifiable {
    var id: Int64
    var level: CEFRLevel
    var finishedAt: Date?
    var items: [HistoryItem]

    var passed: Int { items.filter { $0.outcome?.result.outcome == .pass }.count }
}

/// Reads the most recent finished sessions (§2.3: at most 10 are kept).
nonisolated struct HistoryStore: Sendable {
    let database: AppDatabase

    func load() async throws -> [HistorySession] {
        try await database.writer.read { db in
            let sessions = try Session
                .filter(Column("status") == SessionStatus.done.rawValue)
                .order(Column("finished_at").desc, Column("id").desc)
                .limit(PracticeStore.keptSessions)
                .fetchAll(db)
            return try sessions.map { session in
                let items = try SessionItem.filter(Column("session_id") == session.id).order(Column("position")).fetchAll(db)
                return HistorySession(
                    id: session.id!,
                    level: session.level,
                    finishedAt: session.finishedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    items: try items.map { try Self.item($0, db: db) }
                )
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
        var outcome: ScoredAnswer?
        if let event {
            let detail = event.detail.flatMap { try? JSONDecoder().decode(PracticeEventDetail.self, from: Data($0.utf8)) }
            // The comparison is recomputed from the stored transcription, as on the practice screen.
            var result = AnswerMatcher.score(de: sentence.de, spoken: sentence.spoken, heard: detail?.heard,
                                             skipped: detail?.reason == .skipped)
            result.outcome = event.outcome
            outcome = ScoredAnswer(heard: detail?.heard, result: result)
        }
        return HistoryItem(position: item.position, mode: item.mode, sentence: sentence,
                           annotation: try sentence.decodedAnnotation(), outcome: outcome)
    }
}
