import Foundation

/// A problem found in a seed file. `key` is the entry or sentence it concerns, if any.
nonisolated struct SeedIssue: Error, LocalizedError, Hashable, Sendable {
    var seed: String
    var key: String?
    var message: String

    var errorDescription: String? {
        if let key { "\(seed) · \(key): \(message)" } else { "\(seed): \(message)" }
    }
}

/// The mechanical checks of DESIGN.md §4.3. Used by the importer before writing anything (§2.5)
/// and by the unit test over the bundled seeds.
nonisolated enum SeedValidator {
    /// Upper bound of words per sentence, punctuation not counted (lenient).
    static let maxWords = 30
    /// Every sentence carries a translation in each supported native language (§2.1).
    static let requiredLanguages = NativeLanguage.supported.map(\.code)

    private static let posCodes = Set(PartOfSpeech.allCases.map(\.rawValue))
    private static let cases = Set(GrammaticalCase.allCases.map(\.rawValue))
    private static let verbForms = Set(VerbForm.allCases.map(\.rawValue))
    private static let genders = Set(NounGender.allCases.map(\.rawValue))
    private static let entryGenders: Set = ["Masc", "Fem", "Neut", "Plur"]
    private static let spanLabels = Set(Constituent.allCases.map(\.rawValue) + ClauseKind.allCases.map(\.rawValue))

    static func validate(_ file: SeedFile) -> [SeedIssue] {
        var issues: [SeedIssue] = []
        let seedId = file.seed.id
        func issue(_ key: String?, _ message: String) {
            issues.append(SeedIssue(seed: seedId, key: key, message: message))
        }

        // Header
        if seedId.isEmpty || file.seed.title.isEmpty { issue(nil, "the header needs an id and a title") }
        if file.seed.version < 1 { issue(nil, "the version must be 1 or higher") }
        let prefix = file.seed.level.rawValue.lowercased() + "."

        // Entries
        var entries: [String: SeedEntry] = [:]
        for entry in file.entries {
            let key = entry.key
            if entries[key] != nil { issue(key, "duplicate entry key") }
            entries[key] = entry
            if !isKey(key, prefix: prefix, numberedParts: 0...1) { issue(key, "malformed entry key") }
            if entry.headword.isEmpty || entry.lemma.isEmpty { issue(key, "headword and lemma must not be empty") }
            if !posCodes.contains(entry.pos) || entry.pos == PartOfSpeech.punct.rawValue { issue(key, "unknown POS \(entry.pos)") }
            if let gender = entry.gender, !entryGenders.contains(gender) { issue(key, "unknown gender \(gender)") }
        }
        for entry in file.entries {
            guard let parent = entry.parent else { continue }
            if parent == entry.key || entries[parent] == nil { issue(entry.key, "parent \(parent) is not an entry of this file") }
        }

        // Sentences
        var sentenceKeys: Set<String> = []
        for sentence in file.sentences {
            let key = sentence.key
            if !sentenceKeys.insert(key).inserted { issue(key, "duplicate sentence key") }
            if !isKey(key, prefix: prefix, numberedParts: 1...2) { issue(key, "malformed sentence key") }
            for message in check(sentence, entries: entries) { issue(key, message) }
        }
        return issues
    }

    /// Problems of one sentence, as messages.
    static func check(_ sentence: SeedSentence, entries: [String: SeedEntry]) -> [String] {
        var problems: [String] = []
        let words = sentence.words
        let range = words.indices

        // Text
        if sentence.de.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("de is empty") }
        if words.map(\.form).joined().filter({ !$0.isWhitespace }) != sentence.de.filter({ !$0.isWhitespace }) {
            problems.append("the forms of words do not reproduce de")
        }
        let wordCount = words.filter { !$0.isPunctuation }.count
        if wordCount > maxWords { problems.append("\(wordCount) words, more than \(maxWords)") }

        // spoken
        let hasDigit = sentence.de.contains(where: \.isNumber)
        if let spoken = sentence.spoken {
            if spoken.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("spoken is empty") }
            if spoken.contains(where: \.isNumber) { problems.append("spoken contains digits") }
        } else if hasDigit {
            problems.append("de contains digits but spoken is missing")
        }

        // Translations
        for language in requiredLanguages {
            guard let text = sentence.translations[language], !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                problems.append("missing \(language) translation")
                continue
            }
            switch language {
            case "zh" where !containsHan(text): problems.append("the zh translation has no Chinese characters")
            case "en" where containsHan(text): problems.append("the en translation contains Chinese characters")
            default: break
            }
        }

        // Annotation rows (§2.4, §5)
        for (index, word) in words.enumerated() {
            if let message = checkRow(word) { problems.append("token \(index) \"\(word.form)\": \(message)") }
        }
        for span in sentence.spans {
            if !spanLabels.contains(span.fn) { problems.append("unknown span label \(span.fn)") }
            if span.tokens.isEmpty { problems.append("span \(span.fn) has no tokens") }
            for token in span.tokens {
                if !range.contains(token) { problems.append("span \(span.fn) token \(token) out of range") }
                else if words[token].isPunctuation { problems.append("span \(span.fn) contains punctuation") }
            }
        }

        // Entries
        if sentence.entries.isEmpty { problems.append("links no entry") }
        for link in sentence.entries {
            guard let entry = entries[link.key] else {
                problems.append("entry \(link.key) is not in this file")
                continue
            }
            if link.tokens.isEmpty { problems.append("entry \(link.key) has no tokens") }
            guard link.tokens.allSatisfy(range.contains) else {
                problems.append("entry \(link.key) token out of range")
                continue
            }
            if link.tokens.contains(where: { words[$0].isPunctuation }) { problems.append("entry \(link.key) includes punctuation") }
            if !link.tokens.isEmpty, !lemma(entry.lemma, matches: link.tokens.map { words[$0].lemma }) {
                problems.append("the tokens of entry \(link.key) do not have its lemma \(entry.lemma)")
            }
        }
        return problems
    }

    /// Item 4 and item 5 of one row, by part of speech (§2.4).
    private static func checkRow(_ word: AnnotationToken) -> String? {
        guard posCodes.contains(word.pos) else { return "unknown POS \(word.pos)" }
        let feature = word.feature
        switch word.pos {
        case "NOUN", "PROPN", "PRON", "DET", "ADP":
            if !cases.contains(feature) { return "needs a case, has \"\(feature)\"" }
        case "VERB", "AUX":
            if !verbForms.contains(feature) { return "needs a verb form, has \"\(feature)\"" }
        case "ADJ":
            if !feature.isEmpty && !cases.contains(feature) { return "needs a case or nothing, has \"\(feature)\"" }
        default:
            if !feature.isEmpty { return "item 4 must be empty, has \"\(feature)\"" }
        }
        if word.pos == "NOUN" {
            guard let gender = word.gender else { return "a noun needs item 5 (gender)" }
            if !genders.contains(gender) { return "unknown gender \(gender)" }
        } else if word.gender != nil {
            return "item 5 is only for nouns"
        }
        if word.form.trimmingCharacters(in: .whitespaces).isEmpty { return "empty form" }
        return nil
    }

    /// The entry's lemma is the tokens' lemma (a separable verb gives it on both parts), the
    /// lemmas of a phrase in order, or part of a compound or feminine form (`Seeluft`, `Lehrerin`).
    static func lemma(_ lemma: String, matches tokenLemmas: [String]) -> Bool {
        let target = lemma.lowercased()
        var distinct: [String] = []
        for token in tokenLemmas.map({ $0.lowercased() }) where distinct.last != token {
            distinct.append(token)
        }
        if distinct.joined(separator: " ") == target { return true }
        return distinct.contains { $0.contains(target) }
    }

    /// `<level>.<name>` followed by `numberedParts` numeric segments, e.g. `a1.abfahren`,
    /// `a2.bank.2`, `a1.abholen.2`, `a2.bank.2.1`.
    static func isKey(_ key: String, prefix: String, numberedParts: ClosedRange<Int>) -> Bool {
        guard key.hasPrefix(prefix) else { return false }
        let parts = key.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard let name = parts.first, !name.isEmpty,
              name.allSatisfy({ ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "_" }) else { return false }
        let numbers = parts.dropFirst()
        guard numberedParts.contains(numbers.count) else { return false }
        return numbers.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }
}
