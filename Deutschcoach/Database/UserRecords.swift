import Foundation
import GRDB

// User-layer records (DESIGN.md §2.2). JSON columns are kept as JSON text.

nonisolated enum SentenceMode: String, Codable, Sendable, CaseIterable {
    case shadow, cloze
    /// UI name “翻译” (Translation); the code is kept from version 0.1.
    case recall
}

nonisolated enum ItemStatus: String, Codable, Sendable {
    case pending, done, skipped
}

nonisolated enum SessionStatus: String, Codable, Sendable {
    case active, done
}

nonisolated enum PracticeOutcome: String, Codable, Sendable {
    case pass, fail
    case notAttempted = "not_attempted"
}

/// A sentence's place on the mastery ladder, 1–7. A missing row means a new sentence:
/// `MasteryRules.newLevel`, never seen (DESIGN.md §3.5).
nonisolated struct Progress: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "progress"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var sentenceId: Int64
    var level: Int
    /// Unix time in seconds.
    var lastSeenAt: Int64?
}

/// Append-only (DESIGN.md §2.2). `session_id` has no foreign key so events survive pruning.
nonisolated struct PracticeEvent: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "practice_event"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: Int64?
    /// Unix time in seconds.
    var ts: Int64
    var sessionId: Int64?
    var sentenceId: Int64
    var mode: SentenceMode
    var outcome: PracticeOutcome
    /// JSON-encoded `PracticeEventDetail`.
    var detail: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Why a sentence was not attempted.
nonisolated enum NotAttemptedReason: String, Codable, Sendable {
    case skipped
    case noSpeech = "no_speech"
}

/// The `detail` column of `practice_event`.
nonisolated struct PracticeEventDetail: Codable, Sendable, Equatable {
    /// The final recognized text.
    var heard: String?
    var engine: String?
    var reason: NotAttemptedReason?
    /// Token indices of the sentence that did not match.
    var mismatched: [Int]?
}

nonisolated struct Session: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "session"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: Int64?
    var level: CEFRLevel
    var status: SessionStatus
    /// Unix time in seconds.
    var createdAt: Int64
    var finishedAt: Int64?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

nonisolated struct SessionItem: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "session_item"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var sessionId: Int64
    /// 1–10.
    var position: Int
    var sentenceId: Int64
    var mode: SentenceMode
    var blankEntryId: Int64?
    var status: ItemStatus
}
