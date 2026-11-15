import Foundation
import GRDB

/// A generated sentence that passed validation, ready to be stored.
nonisolated struct ValidatedSentence: Sendable, Equatable {
    var request: SentenceRequest
    var de: String
    var translation: String
    var annotation: SentenceAnnotation
    var targets: [TargetTokens]
}

/// The lemma and known forms of vocabulary targets, for §4.3 rule 5.
nonisolated struct VocabLexicon: Sendable {
    struct Entry: Sendable {
        var lemma: String
        /// Lowercased forms from `word_form`.
        var forms: Set<String>
    }

    var entries: [Int64: Entry]

    static func load(elementIds: [Int64], from db: Database) throws -> VocabLexicon {
        var entries: [Int64: Entry] = [:]
        for id in Set(elementIds) {
            guard let lemma = try String.fetchOne(db, sql: "SELECT lemma FROM vocab_detail WHERE element_id = ?", arguments: [id]) else {
                continue
            }
            let forms = try String.fetchAll(db, sql: "SELECT form FROM word_form WHERE element_id = ?", arguments: [id])
            entries[id] = Entry(lemma: lemma, forms: Set(forms.map { $0.lowercased() }))
        }
        return VocabLexicon(entries: entries)
    }
}

/// Basic checks of a generated sentence (DESIGN.md §4.3). Linguistic judgment is left to the LLM;
/// labels outside the label set are accepted.
nonisolated struct SentenceValidator: Sendable {
    /// §4.3 rule 6: lenient upper limit of words per sentence, punctuation not counted.
    static let maxWords = 25

    var lexicon: VocabLexicon
    /// The language the translation must be written in (`zh`, `en`); `nil` skips the check.
    var nativeLang: String?

    /// §4.3 rule 7: a Chinese translation contains Han characters, an English one none.
    static func isWritten(_ text: String, in language: String) -> Bool {
        let han = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        switch language {
        case "zh": return han
        case "en": return !han && text.unicodeScalars.contains { CharacterSet.letters.contains($0) && $0.isASCII }
        default: return true
        }
    }

    func validate(_ sentence: GeneratedSentence, for request: SentenceRequest) -> Result<ValidatedSentence, ValidationFailure> {
        // Rule 1: the position is the requested one.
        guard sentence.position == request.position else {
            return .failure(.init(position: request.position, reason: "position \(sentence.position) does not match \(request.position)"))
        }
        let fail = { (reason: String) in Result<ValidatedSentence, ValidationFailure>.failure(.init(position: request.position, reason: reason)) }

        // Rule 6: non-empty text.
        let de = sentence.de.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = sentence.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !de.isEmpty else { return fail("empty sentence") }
        guard !translation.isEmpty else { return fail("empty translation") }
        if let nativeLang, !Self.isWritten(translation, in: nativeLang) {
            return fail("translation is not written in \(nativeLang): \(translation)")
        }

        // Rule 2: rows of 4 or 5 items whose forms reproduce the sentence.
        if let row = sentence.words.firstIndex(where: { $0.count != 4 && $0.count != 5 }) {
            return fail("row \(row) has \(sentence.words[row].count) items")
        }
        let tokens = sentence.words.map { row in
            AnnotationToken(form: row[0], lemma: row[1], pos: row[2], feature: row[3], gender: row.count == 5 ? row[4] : nil)
        }
        let joined = Self.withoutWhitespace(tokens.map(\.form).joined())
        guard joined == Self.withoutWhitespace(de) else {
            return fail("word forms \"\(tokens.map(\.form).joined(separator: " "))\" do not reproduce the sentence")
        }

        // Rule 6: word count.
        let wordCount = tokens.filter { !$0.isPunctuation }.count
        guard wordCount <= Self.maxWords else { return fail("\(wordCount) words, more than \(Self.maxWords)") }

        // Rule 3: token indices in range.
        let range = 0..<tokens.count
        for span in sentence.spans where span.tokens.isEmpty || !span.tokens.allSatisfy(range.contains) {
            return fail("span \(span.fn) has invalid tokens \(span.tokens)")
        }
        for target in sentence.targets where target.tokens.isEmpty || !target.tokens.allSatisfy(range.contains) {
            return fail("target \(target.elementId) has invalid tokens \(target.tokens)")
        }

        // Rule 4: every requested target is located.
        var targets: [TargetTokens] = []
        for requested in request.targets {
            guard let located = sentence.targets.first(where: { $0.elementId == requested.elementId }) else {
                return fail("target \(requested.elementId) (\(requested.title)) missing")
            }
            // Rule 5: vocabulary targets match the lexicon entry.
            if requested.kind == .vocab, let entry = lexicon.entries[requested.elementId] {
                let matches = located.tokens.contains { index in
                    let token = tokens[index]
                    return token.lemma.caseInsensitiveCompare(entry.lemma) == .orderedSame
                        || entry.forms.contains(token.form.lowercased())
                }
                guard matches else {
                    let found = located.tokens.map { tokens[$0].form }.joined(separator: " ")
                    return fail("target \(requested.title) located at \"\(found)\", which is not a form of \(entry.lemma)")
                }
            }
            targets.append(located)
        }

        return .success(ValidatedSentence(
            request: request,
            de: de,
            translation: translation,
            annotation: SentenceAnnotation(words: tokens, spans: sentence.spans),
            targets: targets
        ))
    }

    private static func withoutWhitespace(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }
}

nonisolated struct ValidationFailure: Error, Sendable, Equatable {
    var position: Int
    var reason: String
}
