import Foundation
import GRDB

/// A sentence with everything needed to practice and score it.
nonisolated struct PracticeItem: Sendable, Equatable {
    struct ItemElement: Sendable, Equatable {
        var id: Int64
        var kind: ElementKind
        var role: SentenceElementRole
        var title: String
        /// Token indices in the sentence.
        var tokens: [Int]
        /// Vocabulary only: forms from `word_form` and the lemma, normalized like recognized words.
        var forms: Set<String>
        /// Separable verbs only: the prefix (`auf`), normalized.
        var separablePrefix: String?
    }

    var sentence: Sentence
    var annotation: SentenceAnnotation
    /// Cloze blanks (token indices); empty for other modes.
    var blanks: [Int]
    var elements: [ItemElement]

    var mode: SentenceMode { sentence.mode }
    var targets: [ItemElement] { elements.filter { $0.role == .target } }

    func translation(for language: String) -> String {
        sentence.translation(for: language) ?? ""
    }

    static func load(_ sentence: Sentence, from db: Database) throws -> PracticeItem {
        guard let annotation = try sentence.decodedAnnotation() else {
            throw DatabaseError(message: "sentence \(sentence.id ?? 0) has no annotation")
        }
        let blanks = try sentence.blanks.map { try JSONDecoder().decode([Int].self, from: Data($0.utf8)) } ?? []

        let rows = try Row.fetchAll(db, sql: """
            SELECT se.element_id, se.role, se.tokens, e.kind, e.title, v.unit_type, v.verb_forms
            FROM sentence_element se
            JOIN element e ON e.id = se.element_id
            LEFT JOIN vocab_detail v ON v.element_id = se.element_id
            WHERE se.sentence_id = ?
            ORDER BY se.role DESC, e.kind DESC, se.element_id
            """, arguments: [sentence.id])
        var elements: [ItemElement] = []
        for row in rows {
            let id: Int64 = row["element_id"]
            guard
                let kind = ElementKind(rawValue: row["kind"]),
                let role = SentenceElementRole(rawValue: row["role"])
            else { continue }
            let tokensJSON: String? = row["tokens"]
            let tokens = try tokensJSON.map { try JSONDecoder().decode([Int].self, from: Data($0.utf8)) } ?? []

            var forms: Set<String> = []
            var prefix: String?
            if kind == .vocab {
                let raw = try String.fetchAll(db, sql: """
                    SELECT form FROM word_form WHERE element_id = ?
                    UNION SELECT lemma FROM vocab_detail WHERE element_id = ?
                    """, arguments: [id, id])
                forms = Set(raw.map(WordAligner.normalize).filter { !$0.isEmpty })
                if row["unit_type"] as String? == "separable_verb",
                   let json = row["verb_forms"] as String?,
                   let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                   let value = object["prefix"] as? String {
                    prefix = WordAligner.normalize(value)
                }
            }
            elements.append(ItemElement(id: id, kind: kind, role: role, title: row["title"], tokens: tokens, forms: forms, separablePrefix: prefix))
        }
        return PracticeItem(sentence: sentence, annotation: annotation, blanks: blanks, elements: elements)
    }
}
