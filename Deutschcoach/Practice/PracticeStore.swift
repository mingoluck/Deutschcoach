import Foundation
import GRDB
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "practice")

/// A session item with everything needed to show and score it.
nonisolated struct PracticeItem: Sendable, Equatable {
    var sessionId: Int64
    var position: Int
    var mode: SentenceMode
    var sentence: Sentence
    var annotation: SentenceAnnotation
    /// Cloze blanks (token indices); empty for other modes.
    var blanks: [Int]
    /// Austrian or Swiss entries of the sentence, shown as a tag (§3.3).
    var regional: [RegionalEntry] = []

    func translation(for language: String) -> String {
        sentence.translation(for: language) ?? ""
    }
}

/// An Austrian or Swiss entry linked to a sentence (DESIGN.md §3.3).
nonisolated struct RegionalEntry: Sendable, Equatable, Hashable {
    var region: Region
    /// As in the list, with its cross-reference, e.g. `das Stiegenhaus, ¨-er (A) → D, CH: Treppenhaus`.
    var headword: String

    static func load(sentenceId: Int64, db: Database) throws -> [RegionalEntry] {
        try Row.fetchAll(db, sql: """
            SELECT e.region, e.headword FROM sentence_entry se JOIN entry e ON e.id = se.entry_id
            WHERE se.sentence_id = ? AND e.region IS NOT NULL ORDER BY e.sort
            """, arguments: [sentenceId])
            .compactMap { row in Region(rawValue: row["region"]).map { RegionalEntry(region: $0, headword: row["headword"]) } }
    }
}

/// What one answer writes (DESIGN.md §3.4).
nonisolated struct AnswerRecord: Sendable, Equatable {
    var outcome: PracticeOutcome
    var reason: NotAttemptedReason?
    var heard: String?
    var engine: String?
    var mismatched: [Int]
}

/// Database side of practice: sessions, answers, progress (DESIGN.md §2.2, §3).
nonisolated struct PracticeStore: Sendable {
    let database: AppDatabase
    var now: @Sendable () -> Date = { Date() }
    /// Done sessions kept for the history (§2.3).
    static let keptSessions = 10

    private var timestamp: Int64 { Int64(now().timeIntervalSince1970) }

    // MARK: - Sessions (§3.1)

    /// The `active` session, if any.
    func activeSession() async throws -> Int64? {
        try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM session WHERE status = 'active' ORDER BY id DESC LIMIT 1")
        }
    }

    /// The sentences of the libraries `seedIds` that a session can be built from (§3.2).
    func candidates(seedIds: [String]) async throws -> [SessionBuilder.Candidate] {
        try await database.writer.read { db in
            try SessionBuilder.loadCandidates(seedIds: seedIds, from: db)
        }
    }

    /// Stores a new `active` session with `picks`; nil when there are none.
    func createSession(seedIds: [String], picks: [SessionBuilder.Pick]) async throws -> Int64? {
        guard !picks.isEmpty else { return nil }
        let createdAt = timestamp
        let id = try await database.writer.write { db in
            var session = Session(seedIds: seedIds, status: .active, createdAt: createdAt)
            try session.insert(db)
            let id = session.id!
            for (offset, pick) in picks.enumerated() {
                try SessionItem(sessionId: id, position: offset + 1, sentenceId: pick.sentenceId, mode: pick.mode,
                                status: .pending).insert(db)
            }
            return id
        }
        logger.info("Session #\(id) from \(seedIds, privacy: .public): \(picks.map(\.mode.rawValue), privacy: .public)")
        return id
    }

    /// The first pending item of the session, nil when all are answered.
    func nextItem(inSession sessionId: Int64) async throws -> PracticeItem? {
        try await database.writer.read { db in
            guard let item = try SessionItem
                .filter(Column("session_id") == sessionId && Column("status") == ItemStatus.pending.rawValue)
                .order(Column("position"))
                .fetchOne(db)
            else { return nil }
            return try Self.load(item, db: db)
        }
    }

    static func load(_ item: SessionItem, db: Database) throws -> PracticeItem {
        guard let sentence = try Sentence.fetchOne(db, key: item.sentenceId) else {
            throw DatabaseError(message: "sentence \(item.sentenceId) is missing")
        }
        let blanks = item.mode == .cloze ? try clozeBlanks(sentenceId: item.sentenceId, db: db) : []
        return PracticeItem(sessionId: item.sessionId, position: item.position, mode: item.mode, sentence: sentence,
                            annotation: try sentence.decodedAnnotation(), blanks: blanks,
                            regional: try RegionalEntry.load(sentenceId: item.sentenceId, db: db))
    }

    /// §3.2: the tokens of every entry linked to the sentence, in order.
    static func clozeBlanks(sentenceId: Int64, db: Database) throws -> [Int] {
        let links = try SentenceEntry.filter(Column("sentence_id") == sentenceId).fetchAll(db)
        return Set(links.flatMap(\.decodedTokens)).sorted()
    }

    /// §3.1: ends the `active` session early because the checked libraries changed. Answered
    /// items stay for the history; pending ones are deleted, and so is a session without answers.
    func endActiveSession() async throws {
        let ts = timestamp
        try await database.writer.write { db in
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM session WHERE status = 'active'") else { return }
            try db.execute(sql: "DELETE FROM session_item WHERE session_id = ? AND status = 'pending'", arguments: [id])
            if try SessionItem.filter(Column("session_id") == id).fetchCount(db) == 0 {
                try db.execute(sql: "DELETE FROM session WHERE id = ?", arguments: [id])
            } else {
                try db.execute(sql: "UPDATE session SET status = 'done', finished_at = ? WHERE id = ?", arguments: [ts, id])
                try Self.pruneHistory(db)
            }
        }
    }

    /// The progress of one library (§6).
    func libraryProgress(seedId: String) async throws -> LibraryProgress? {
        try await database.writer.read { db in try LibraryProgress.fetch(seedId: seedId, db)[seedId] }
    }

    /// Answered and total items of a session.
    func progress(ofSession sessionId: Int64) async throws -> (answered: Int, total: Int) {
        try await database.writer.read { db in
            let total = try SessionItem.filter(Column("session_id") == sessionId).fetchCount(db)
            let pending = try SessionItem.filter(Column("session_id") == sessionId && Column("status") == ItemStatus.pending.rawValue).fetchCount(db)
            return (total - pending, total)
        }
    }

    // MARK: - Answers (§3.4, §3.5)

    /// Writes the event, the progress and the item status in one transaction. When it was the
    /// session's last pending item, the session becomes `done` and history is pruned (§2.3).
    /// Returns whether the session is done.
    @discardableResult
    func record(_ answer: AnswerRecord, for item: PracticeItem) async throws -> Bool {
        let ts = timestamp
        let detail = PracticeEventDetail(heard: answer.heard, engine: answer.engine, reason: answer.reason,
                                         mismatched: answer.mismatched.isEmpty ? nil : answer.mismatched)
        let detailJSON = String(decoding: try JSONEncoder().encode(detail), as: UTF8.self)
        return try await database.writer.write { db in
            var event = PracticeEvent(ts: ts, sessionId: item.sessionId, sentenceId: item.sentence.id,
                                      mode: item.mode, outcome: answer.outcome, detail: detailJSON)
            try event.insert(db)
            try Self.recomputeProgress(sentenceId: item.sentence.id, db: db)
            let status: ItemStatus = answer.reason == .skipped ? .skipped : .done
            try db.execute(sql: "UPDATE session_item SET status = ? WHERE session_id = ? AND position = ?",
                           arguments: [status.rawValue, item.sessionId, item.position])
            let pending = try SessionItem.filter(Column("session_id") == item.sessionId && Column("status") == ItemStatus.pending.rawValue).fetchCount(db)
            guard pending == 0 else { return false }
            try db.execute(sql: "UPDATE session SET status = 'done', finished_at = ? WHERE id = ?", arguments: [ts, item.sessionId])
            try Self.pruneHistory(db)
            return true
        }
    }

    /// Replays all events of the sentence, in every mode, through the ladder rules;
    /// `last_seen_at` is the newest event. Reads only the columns it needs, so the v4 migration
    /// can use it whatever the event table looks like later.
    static func recomputeProgress(sentenceId: Int64, db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT ts, outcome FROM practice_event WHERE sentence_id = ? ORDER BY ts, id",
                                    arguments: [sentenceId])
        guard let last = rows.last else {
            try db.execute(sql: "DELETE FROM progress WHERE sentence_id = ?", arguments: [sentenceId])
            return
        }
        let outcomes = rows.compactMap { PracticeOutcome(rawValue: $0["outcome"]) }
        try Progress(sentenceId: sentenceId, level: MasteryRules.level(after: outcomes), lastSeenAt: last["ts"]).upsert(db)
    }

    /// Recomputes all progress from `practice_event`, e.g. after the rules changed (§3.5).
    func recomputeAllProgress() async throws {
        try await database.writer.write { db in try Self.recomputeAllProgress(db) }
    }

    static func recomputeAllProgress(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM progress")
        // Events of sentences that no longer exist cannot have a progress row.
        let ids = try Int64.fetchAll(db, sql: "SELECT DISTINCT sentence_id FROM practice_event WHERE sentence_id IN (SELECT id FROM sentence)")
        for id in ids {
            try recomputeProgress(sentenceId: id, db: db)
        }
    }

    /// Keeps the `keptSessions` most recent done sessions; items cascade, events stay.
    static func pruneHistory(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM session
            WHERE status = 'done'
              AND id NOT IN (SELECT id FROM session WHERE status = 'done'
                             ORDER BY finished_at DESC, id DESC LIMIT \(keptSessions))
            """)
    }
}
