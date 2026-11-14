import Foundation
import GRDB

// User-layer records (DESIGN.md §2.2). JSON columns are kept as JSON text.

nonisolated enum BatchStatus: String, Codable, Sendable {
    case generating, ready, active, done
}

nonisolated enum SentenceMode: String, Codable, Sendable, CaseIterable {
    case shadow, cloze, recall
}

nonisolated enum SentenceStatus: String, Codable, Sendable {
    case pending, done, skipped
}

nonisolated enum SentenceElementRole: String, Codable, Sendable {
    case target, incidental
}

nonisolated struct Batch: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "batch"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: Int64?
    var status: BatchStatus
    var nativeLang: String
    var model: String?
    /// Unix time in seconds.
    var createdAt: Int64
    var startedAt: Int64?
    var finishedAt: Int64?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

nonisolated struct Sentence: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "sentence"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: Int64?
    var batchId: Int64
    var position: Int
    var mode: SentenceMode
    var status: SentenceStatus
    var de: String
    /// JSON object: language code → translation, e.g. `{"zh": "…"}`.
    var translations: String
    /// JSON `{"words": [...], "spans": [...]}`.
    var annotation: String?
    /// JSON array of token indices.
    var blanks: String?
    var model: String?
    var createdAt: Int64?
    var flagged: Bool

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    func decodedAnnotation() throws -> SentenceAnnotation? {
        guard let annotation else { return nil }
        return try JSONDecoder().decode(SentenceAnnotation.self, from: Data(annotation.utf8))
    }

    func translation(for language: String) -> String? {
        guard let dictionary = try? JSONDecoder().decode([String: String].self, from: Data(translations.utf8)) else {
            return nil
        }
        return dictionary[language]
    }
}

nonisolated struct SentenceElement: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sentence_element"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var sentenceId: Int64
    var elementId: Int64
    var role: SentenceElementRole
    /// JSON array of token indices.
    var tokens: String?
}

nonisolated enum MasteryDimension: String, Codable, Sendable, CaseIterable {
    case pronunciation, recall
}

nonisolated enum PracticeOutcome: String, Codable, Sendable {
    case pass, fail
    case notAttempted = "not_attempted"
}

/// A missing row means level 1, never seen (DESIGN.md §2.4).
nonisolated struct Mastery: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mastery"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var elementId: Int64
    var dimension: MasteryDimension
    var level: Int
    /// Unix time in seconds.
    var lastSeenAt: Int64?
}

/// Append-only (DESIGN.md §2.2). `sentence_id` has no foreign key so events survive pruning.
nonisolated struct PracticeEvent: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "practice_event"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: Int64?
    /// Unix time in seconds.
    var ts: Int64
    var sentenceId: Int64?
    var elementId: Int64
    var dimension: MasteryDimension
    var mode: SentenceMode
    var outcome: PracticeOutcome
    /// JSON-encoded `PracticeEventDetail`.
    var detail: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Why an element was not attempted (DESIGN.md §2.2 `practice_event.detail`).
nonisolated enum NotAttemptedReason: String, Codable, Sendable {
    case skipped
    case noSpeech = "no_speech"
    case paraphrase
    case unclear
}

/// The `detail` column of `practice_event`.
nonisolated struct PracticeEventDetail: Codable, Sendable, Equatable {
    /// The final recognized text.
    var heard: String?
    var engine: String?
    var reason: NotAttemptedReason?
    var judge: JudgeVerdict?
}
