import Foundation
import GRDB

// Content-layer records (DESIGN.md §2.2). JSON columns are kept as JSON text.

nonisolated enum CEFRLevel: String, Codable, Sendable, CaseIterable {
    case a1 = "A1", a2 = "A2", b1 = "B1", b2 = "B2"
}

nonisolated enum ContentStatus: String, Codable, Sendable {
    case active, retired
}

/// Austrian or Swiss usage (DESIGN.md §2.4).
nonisolated enum Region: String, Codable, Sendable {
    case a = "A", ch = "CH"
}

/// Where a sentence comes from (DESIGN.md §2.2).
nonisolated enum SentenceSource: String, Codable, Sendable {
    /// An example sentence of the Goethe word list.
    case goethe
    /// Written offline for a word-group item.
    case generated
    /// Reserved for sentences generated at run time in a later version.
    case llm
}

nonisolated enum SeedOrigin: String, Codable, Sendable {
    case bundled, user
}

/// One seed file that was imported (DESIGN.md §2.5).
nonisolated struct SeedImport: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "seed_import"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var seedId: String
    var title: String
    var level: CEFRLevel
    var version: Int
    var origin: SeedOrigin
    var entryCount: Int
    var sentenceCount: Int
    /// Unix time in seconds.
    var importedAt: Int64

    var id: String { seedId }
}

/// One headword of a word list.
nonisolated struct Entry: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "entry"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: Int64
    var key: String
    var seedId: String
    var level: CEFRLevel
    var headword: String
    var lemma: String
    var pos: String
    var gender: String?
    var grp: String?
    var region: Region?
    var parentId: Int64?
    var sort: Int
    var status: ContentStatus
}

nonisolated struct Sentence: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sentence"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: Int64
    var key: String
    var seedId: String
    var level: CEFRLevel
    var source: SentenceSource
    var de: String
    var spoken: String?
    /// JSON object: language code → translation, e.g. `{"en": "…", "zh": "…"}`.
    var translations: String
    /// JSON `{"words": [...], "spans": [...]}`.
    var annotation: String
    var sort: Int
    var status: ContentStatus

    /// The text answers are matched against (DESIGN.md §3.4).
    var matchText: String { spoken ?? de }

    func decodedAnnotation() throws -> SentenceAnnotation {
        try JSONDecoder().decode(SentenceAnnotation.self, from: Data(annotation.utf8))
    }

    func translation(for language: String) -> String? {
        guard let dictionary = try? JSONDecoder().decode([String: String].self, from: Data(translations.utf8)) else {
            return nil
        }
        return dictionary[language]
    }
}

nonisolated struct SentenceEntry: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sentence_entry"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var sentenceId: Int64
    var entryId: Int64
    /// JSON array of token indices.
    var tokens: String

    var decodedTokens: [Int] {
        (try? JSONDecoder().decode([Int].self, from: Data(tokens.utf8))) ?? []
    }
}
