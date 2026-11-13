import Foundation

/// The grammatical annotation of one sentence, as produced by the LLM (DESIGN.md §4.1) and
/// stored in `sentence.annotation`.
nonisolated struct SentenceAnnotation: Codable, Sendable, Equatable {
    var words: [AnnotationToken]
    var spans: [AnnotationSpan]
}

/// One row of `words`: `[form, lemma, POS, item 4, item 5 (nouns only)]`.
/// The array index of the row is the token index.
nonisolated struct AnnotationToken: Codable, Sendable, Equatable {
    var form: String
    var lemma: String
    var pos: String
    /// Case, governed case (prepositions), verb form, or empty.
    var feature: String
    /// Nouns only: gender, with `|Plur` for plurals (`Neut|Plur`), or just `Plur`.
    var gender: String?

    init(form: String, lemma: String, pos: String, feature: String, gender: String? = nil) {
        self.form = form
        self.lemma = lemma
        self.pos = pos
        self.feature = feature
        self.gender = gender
    }

    enum DecodingError: Error, Equatable {
        case wrongItemCount(Int)
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let count = container.count ?? 0
        guard count == 4 || count == 5 else { throw DecodingError.wrongItemCount(count) }
        form = try container.decode(String.self)
        lemma = try container.decode(String.self)
        pos = try container.decode(String.self)
        feature = try container.decode(String.self)
        gender = count == 5 ? try container.decode(String.self) : nil
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(form)
        try container.encode(lemma)
        try container.encode(pos)
        try container.encode(feature)
        if let gender { try container.encode(gender) }
    }

    var isPunctuation: Bool { pos == PartOfSpeech.punct.rawValue }
}

/// A constituent or clause over a (possibly non-contiguous) set of token indices.
nonisolated struct AnnotationSpan: Codable, Sendable, Equatable {
    var fn: String
    var tokens: [Int]
}
