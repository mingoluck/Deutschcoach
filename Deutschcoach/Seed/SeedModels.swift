import Foundation

// The seed file format (content layer only, DESIGN.md §2.1).
//
// {
//   "elements": [
//     { "key": "vocab.kind.noun", "kind": "vocab", "level": "A1", "title": "das Kind",
//       "freq_rank": 120,
//       "vocab": { "lemma": "Kind", "pos": "NOUN", "gender": "Neut", "plural": "Kinder" },
//       "forms": [ { "form": "Kindern", "morph": "Dat|Plur" } ],
//       "links": [ { "to": "gram.nom.subject", "kind": "related" } ] }
//   ]
// }
//
// Optional fields: freq_rank, status (default "active"), level_src (default "import"),
// reviewed (default false), forms, links, and the optional fields of each detail.
// Exactly one of vocab / grammar / pattern must be present, matching `kind`.

nonisolated struct SeedFile: Decodable, Sendable {
    var elements: [SeedElement]
}

nonisolated struct SeedElement: Decodable, Sendable {
    var key: String
    var kind: ElementKind
    var level: CEFRLevel
    var title: String
    var freqRank: Int?
    var status: ElementStatus?
    var levelSrc: String?
    var reviewed: Bool?
    var vocab: SeedVocab?
    var grammar: SeedGrammar?
    var pattern: SeedPattern?
    /// Extra word forms beyond those derived from the vocab detail (lemma, plural, verb forms).
    var forms: [SeedForm]?
    var links: [SeedLink]?

    enum CodingKeys: String, CodingKey {
        case key, kind, level, title, status, reviewed, vocab, grammar, pattern, forms, links
        case freqRank = "freq_rank"
        case levelSrc = "level_src"
    }
}

nonisolated struct SeedVocab: Decodable, Sendable {
    var lemma: String
    var pos: String
    var gender: String?
    var plural: String?
    var verbForms: VerbForms?
    var valency: JSONValue?
    var unitType: String?
    var sense: String?

    enum CodingKeys: String, CodingKey {
        case lemma, pos, gender, plural, valency, sense
        case verbForms = "verb_forms"
        case unitType = "unit_type"
    }
}

/// Stored as JSON in `vocab_detail.verb_forms`.
nonisolated struct VerbForms: Codable, Sendable, Equatable {
    /// Present tense, keyed by person: ich, du, er, wir, ihr, sie.
    var praesens: [String: String]?
    /// Simple past, keyed by person.
    var praeteritum: [String: String]?
    var partizip2: String?
    /// Perfect auxiliary: "haben" or "sein".
    var aux: String?
    /// Separable prefix, e.g. "auf" for aufstehen.
    var prefix: String?
}

nonisolated struct SeedGrammar: Decodable, Sendable {
    var category: String
    var annotationLabels: [String]?

    enum CodingKeys: String, CodingKey {
        case category
        case annotationLabels = "annotation_labels"
    }
}

nonisolated struct SeedPattern: Decodable, Sendable {
    var template: String
    var slots: JSONValue?
    var function: String?
}

nonisolated struct SeedForm: Decodable, Sendable {
    var form: String
    var morph: String?
}

nonisolated struct SeedLink: Decodable, Sendable {
    /// Key of the target element.
    var to: String
    var kind: ElementLinkKind
}

/// Free-form JSON, used for columns whose structure is not fixed yet (valency, slots).
nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
