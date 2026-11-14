import Foundation
import GRDB
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "practice")

/// One event to write for an answered sentence.
nonisolated struct EventDraft: Sendable, Equatable {
    var elementId: Int64
    var dimension: MasteryDimension
    var outcome: PracticeOutcome
    var reason: NotAttemptedReason?
}

/// Database operations of the practice flow: batch transitions (DESIGN.md §3.1), writing
/// answers (§3.4), mastery (§3.5) and history pruning (§2.3).
nonisolated struct PracticeStore: Sendable {
    /// §2.3: number of `done` batches kept.
    static let keptBatches = 10

    var database: AppDatabase
    var now: @Sendable () -> Date = { Date() }

    private var timestamp: Int64 { Int64(now().timeIntervalSince1970) }

    // MARK: - Batches

    /// §3.1 on launch: delete leftover `generating` batches, then return the `active` batch,
    /// promoting the `ready` one if there is no active batch. `nil` means one must be generated.
    func prepareOnLaunch() async throws -> Int64? {
        let ts = timestamp
        return try await database.writer.write { db in
            let deleted = try Batch.filter(Column("status") == BatchStatus.generating.rawValue).deleteAll(db)
            if deleted > 0 { logger.info("Deleted \(deleted) leftover generating batch(es)") }
            return try Self.activeOrPromote(db, at: ts)
        }
    }

    /// The `active` batch, or the `ready` one promoted to `active`, or `nil`.
    func activeOrPromote() async throws -> Int64? {
        let ts = timestamp
        return try await database.writer.write { db in try Self.activeOrPromote(db, at: ts) }
    }

    private static func activeOrPromote(_ db: Database, at ts: Int64) throws -> Int64? {
        if let active = try Int64.fetchOne(db, sql: "SELECT id FROM batch WHERE status = 'active' ORDER BY id LIMIT 1") {
            return active
        }
        guard let ready = try Int64.fetchOne(db, sql: "SELECT id FROM batch WHERE status = 'ready' ORDER BY id LIMIT 1") else {
            return nil
        }
        try db.execute(sql: "UPDATE batch SET status = 'active', started_at = ? WHERE id = ?", arguments: [ts, ready])
        logger.info("Batch #\(ready) is now active")
        return ready
    }

    /// §3.1 language change: deletes the `generating`, `ready` and `active` batches.
    /// Their sentences cascade; events stay.
    func discardCurrentBatches() async throws {
        try await database.writer.write { db in
            let deleted = try Batch.filter(["generating", "ready", "active"].contains(Column("status"))).deleteAll(db)
            logger.info("Discarded \(deleted) current batch(es)")
        }
    }

    /// Deletes unfinished batches in another language (generated before a language change).
    func discardBatches(notIn language: String) async throws {
        try await database.writer.write { db in
            let deleted = try Batch
                .filter(["generating", "ready", "active"].contains(Column("status")) && Column("native_lang") != language)
                .deleteAll(db)
            if deleted > 0 { logger.info("Discarded \(deleted) batch(es) not in \(language, privacy: .public)") }
        }
    }

    func hasReadyBatch() async throws -> Bool {
        try await database.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM batch WHERE status = 'ready')") ?? false
        }
    }

    // MARK: - Sentences

    /// The first `pending` sentence of a batch, with everything needed to practice it.
    func nextItem(inBatch batchId: Int64) async throws -> PracticeItem? {
        try await database.writer.read { db in
            guard let sentence = try Sentence.fetchOne(db, sql: """
                SELECT * FROM sentence WHERE batch_id = ? AND status = 'pending' ORDER BY position LIMIT 1
                """, arguments: [batchId])
            else { return nil }
            return try PracticeItem.load(sentence, from: db)
        }
    }

    /// (answered, total) sentences of a batch.
    func progress(ofBatch batchId: Int64) async throws -> (answered: Int, total: Int) {
        try await database.writer.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sentence WHERE batch_id = ?", arguments: [batchId]) ?? 0
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sentence WHERE batch_id = ? AND status = 'pending'", arguments: [batchId]) ?? 0
            return (total - pending, total)
        }
    }

    // MARK: - Answers

    /// Writes the events of one answer, updates mastery and the sentence status, and finishes
    /// the batch when no sentence is left — all in one transaction (§3.4). Returns `true` when
    /// the batch is now `done`.
    @discardableResult
    func record(
        _ events: [EventDraft],
        for item: PracticeItem,
        status: SentenceStatus,
        heard: String?,
        engine: String?,
        judge: JudgeVerdict? = nil
    ) async throws -> Bool {
        let ts = timestamp
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sentence = item.sentence
        return try await database.writer.write { db in
            for draft in events {
                let detail = PracticeEventDetail(heard: heard, engine: engine, reason: draft.reason, judge: judge)
                var event = PracticeEvent(
                    ts: ts,
                    sentenceId: sentence.id,
                    elementId: draft.elementId,
                    dimension: draft.dimension,
                    mode: sentence.mode,
                    outcome: draft.outcome,
                    detail: String(decoding: try encoder.encode(detail), as: UTF8.self)
                )
                try event.insert(db)
            }
            let affected = Set(events.map { Key(elementId: $0.elementId, dimension: $0.dimension) })
            for key in affected {
                try Self.recomputeMastery(key, db: db)
            }
            try db.execute(sql: "UPDATE sentence SET status = ? WHERE id = ?", arguments: [status.rawValue, sentence.id])
            logger.info("""
                Sentence #\(sentence.id ?? 0) \(status.rawValue, privacy: .public) (\(sentence.mode.rawValue, privacy: .public)): \
                \(events.map { "\($0.elementId)/\($0.dimension.rawValue)=\($0.outcome.rawValue)" }, privacy: .public)
                """)

            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sentence WHERE batch_id = ? AND status = 'pending'", arguments: [sentence.batchId]) ?? 0
            guard pending == 0 else { return false }
            try db.execute(sql: "UPDATE batch SET status = 'done', finished_at = ? WHERE id = ?", arguments: [ts, sentence.batchId])
            try Self.pruneHistory(db)
            logger.info("Batch #\(sentence.batchId) done")
            return true
        }
    }

    // MARK: - Mastery

    struct Key: Hashable {
        var elementId: Int64
        var dimension: MasteryDimension
    }

    /// Replays all events of one (element, dimension) through `MasteryRules` (§3.5).
    /// `last_seen_at` is the time of the latest event.
    static func recomputeMastery(_ key: Key, db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT outcome, ts FROM practice_event WHERE element_id = ? AND dimension = ? ORDER BY ts, id
            """, arguments: [key.elementId, key.dimension.rawValue])
        guard !rows.isEmpty else { return }
        let outcomes = rows.compactMap { PracticeOutcome(rawValue: $0["outcome"]) }
        let lastSeen: Int64 = rows.last!["ts"]
        try db.execute(sql: """
            INSERT INTO mastery (element_id, dimension, level, last_seen_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(element_id, dimension) DO UPDATE SET level = excluded.level, last_seen_at = excluded.last_seen_at
            """, arguments: [key.elementId, key.dimension.rawValue, MasteryRules.level(after: outcomes), lastSeen])
    }

    /// Recomputes every mastery row from the events, e.g. after the rules changed.
    func recomputeAllMastery() async throws {
        try await database.writer.write { db in
            let keys = try Row.fetchAll(db, sql: "SELECT DISTINCT element_id, dimension FROM practice_event").compactMap { row -> Key? in
                guard let dimension = MasteryDimension(rawValue: row["dimension"]) else { return nil }
                return Key(elementId: row["element_id"], dimension: dimension)
            }
            for key in keys { try Self.recomputeMastery(key, db: db) }
        }
    }

    // MARK: - History

    /// §2.3: keep the most recent `keptBatches` done batches; sentences cascade, events stay.
    static func pruneHistory(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM batch
            WHERE status = 'done'
              AND id NOT IN (SELECT id FROM batch WHERE status = 'done'
                             ORDER BY finished_at DESC, id DESC LIMIT ?)
            """, arguments: [keptBatches])
        if db.changesCount > 0 { logger.info("Pruned \(db.changesCount) old batch(es)") }
    }
}
