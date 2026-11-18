import Foundation

// The seed file format (DESIGN.md §2.4). One file per word list:
//
// {
//   "seed": { "id": "goethe_a1", "title": "Goethe-Zertifikat A1 Wortliste", "level": "A1", "version": 1 },
//   "entries": [
//     { "key": "a1.abfahren", "headword": "abfahren", "lemma": "abfahren", "pos": "VERB",
//       "gender": null, "group": null, "region": null, "parent": null }
//   ],
//   "sentences": [
//     { "key": "a1.abfahren.1", "source": "goethe",
//       "de": "Wir fahren um zwölf Uhr ab.", "spoken": null,
//       "translations": { "zh": "我们十二点出发。", "en": "We leave at twelve o'clock." },
//       "words": [["Wir", "wir", "PRON", "Nom"], ...],
//       "spans": [{ "fn": "Subj", "tokens": [0] }, ...],
//       "entries": [{ "key": "a1.abfahren", "tokens": [1, 5] }],
//       "orig": null }
//   ]
// }
//
// Entries
// - `headword`: the list's notation, for display. `lemma`: dictionary form, without the article
//   and without `sich` for reflexive verbs. `pos`: a code of §5.2. `gender`: nouns only
//   (`Masc` / `Fem` / `Neut` / `Plur`).
// - `group`: the Wortgruppe name for entries from the word-group pages, else null.
// - `region`: `A` or `CH` for Austrian or Swiss usage, else null.
// - `parent`: key of the main entry for derived sub-entries (↳), else null.
//
// Sentences
// - `de`: the sentence as practiced. `spoken`: the sentence as said, only when it differs from
//   `de`; required whenever `de` contains a digit.
// - `translations`: `zh` and `en`.
// - `words` / `spans`: the annotation (§2.4, §5). Each row of `words` is
//   `[form, lemma, POS, item 4, item 5 (nouns only)]`.
// - `entries`: the entries the sentence illustrates, with their token indices.
// - `orig`: the source text when cleaning changed it, else null. Never displayed.
//
// Optional fields may be null or left out. The checks are in `SeedValidator`.

nonisolated struct SeedFile: Codable, Sendable {
    var seed: SeedHeader
    var entries: [SeedEntry]
    var sentences: [SeedSentence]
}

nonisolated struct SeedHeader: Codable, Sendable, Hashable {
    var id: String
    var title: String
    var level: CEFRLevel
    var version: Int
}

nonisolated struct SeedEntry: Codable, Sendable, Equatable {
    var key: String
    var headword: String
    var lemma: String
    var pos: String
    var gender: String?
    var group: String?
    var region: Region?
    var parent: String?
}

nonisolated struct SeedSentence: Codable, Sendable, Equatable {
    var key: String
    var source: SentenceSource
    var de: String
    var spoken: String?
    var translations: [String: String]
    var words: [AnnotationToken]
    var spans: [AnnotationSpan]
    var entries: [SeedSentenceEntry]
    var orig: String?

    var annotation: SentenceAnnotation { SentenceAnnotation(words: words, spans: spans) }
}

nonisolated struct SeedSentenceEntry: Codable, Sendable, Equatable {
    var key: String
    var tokens: [Int]
}

/// Only the header, for checking whether a bundled seed is newer than the imported one.
nonisolated struct SeedHeaderOnly: Decodable, Sendable {
    var seed: SeedHeader
}
