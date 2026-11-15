import Foundation
import GRDB

// Content-layer records (DESIGN.md §2.2). User-layer records are added in M5.
// JSON columns are kept as raw JSON text here; typed decoding comes when a feature needs it.

nonisolated enum ElementKind: String, Codable, Sendable, CaseIterable {
    case vocab, grammar, pattern
}

nonisolated enum ElementStatus: String, Codable, Sendable {
    case active, candidate, retired
}

nonisolated enum CEFRLevel: String, Codable, Sendable, CaseIterable {
    case a1 = "A1", a2 = "A2", b1 = "B1", b2 = "B2"
}

nonisolated struct Element: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "element"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: Int64?
    var key: String
    var kind: ElementKind
    var level: CEFRLevel
    var title: String
    var freqRank: Int?
    var status: ElementStatus
    var levelSrc: String?
    var reviewed: Bool
    var targetable: Bool

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

nonisolated struct VocabDetail: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "vocab_detail"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var elementId: Int64
    var lemma: String
    var pos: String
    var gender: String?
    var plural: String?
    var verbForms: String?   // JSON
    var valency: String?     // JSON
    var unitType: String
    var sense: String?
}

nonisolated struct GrammarDetail: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "grammar_detail"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var elementId: Int64
    var category: String
    var annotationLabels: String?  // JSON
}

nonisolated struct PatternDetail: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pattern_detail"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var elementId: Int64
    var template: String
    var slots: String?  // JSON
    var function: String?
}

nonisolated enum ElementLinkKind: String, Codable, Sendable {
    /// `from` requires `to` to be mastered first.
    case prerequisite
    case partOf = "part_of"
    case uses
    case related
}

nonisolated struct ElementLink: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "element_link"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var fromId: Int64
    var toId: Int64
    var kind: ElementLinkKind
}

nonisolated struct WordForm: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "word_form"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var form: String
    var elementId: Int64
    var morph: String?
}

/// One seed file that was imported (DESIGN.md §2.5).
nonisolated struct SeedImport: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "seed_import"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var seedId: String
    var title: String
    var version: Int
    var elementCount: Int
    var importedAt: Int64

    var id: String { seedId }
}
