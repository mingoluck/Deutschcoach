import Foundation

/// Word-level alignment of a recognized utterance against a target sentence (DESIGN.md §3.4).
nonisolated struct Alignment: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case match
        /// The word was read as something else.
        case substituted(heard: String)
        /// The word was not heard at all.
        case missing
        /// A foreign name, which is not checked (DESIGN.md §3.4). The last word of a run of
        /// names carries what was heard in place of the whole run; the others carry nil.
        case name(heard: String?)

        /// Whether the word counts as correct.
        var isAccepted: Bool {
            switch self {
            case .match, .name: true
            case .substituted, .missing: false
            }
        }
    }

    struct Word: Sendable, Equatable {
        /// Index into the target token array (the LLM `words` index in later milestones).
        var index: Int
        var text: String
        var status: Status
    }

    /// One entry per target token that contains a word; punctuation tokens are skipped.
    var words: [Word]
    /// Heard words that do not correspond to any target word.
    var extra: [String]

    /// Whether every word is correct (foreign names count as correct).
    var allMatched: Bool { words.allSatisfy(\.status.isAccepted) }
    var matchedCount: Int { words.filter(\.status.isAccepted).count }
}

nonisolated enum WordAligner {
    // MARK: - Normalization

    /// Normalizes a single token: lowercase, ß → ss, punctuation removed, digits spelled out in
    /// German (`3` → `drei`). Returns an empty string for tokens without letters or digits.
    static func normalize(_ token: String) -> String {
        let lowered = token.lowercased(with: german).replacingOccurrences(of: "ß", with: "ss")
        let kept = String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        if !kept.isEmpty, kept.allSatisfy(\.isASCIIDigit), let number = Int(kept) {
            // A lone 1 stands for any form of "ein" (1 km = einen Kilometer); see `matches`.
            return number == 1 && kept == "1" ? digitOne : spellOut(number)
        }
        return unitWords[kept] ?? kept
    }

    /// Key of the digit 1 written by the recognizer. It is not a German word, and normalizing it
    /// again leaves it unchanged.
    static let digitOne = "einziffer"
    /// The forms the digit 1 can stand for.
    private static let einForms: Set = ["ein", "eine", "einen", "einem", "einer", "eines", "eins"]

    /// Unit abbreviations the recognizer writes, and the word said (keys, lower case).
    /// "Kilogramm" and "Kilo" are the same word for matching.
    static let unitWords: [String: String] = [
        "km": "kilometer", "m": "meter", "cm": "zentimeter", "m²": "quadratmeter", "qm": "quadratmeter",
        "kg": "kilo", "kilogramm": "kilo", "g": "gramm", "l": "liter",
    ]

    /// Whether a target key and a heard key are the same word. Only the digit 1 is lenient:
    /// the word "eine" said for "einen" is still a mismatch.
    static func matches(_ target: String, _ heard: String) -> Bool {
        if target == heard { return true }
        if heard == digitOne { return einForms.contains(target) }
        if target == digitOne { return einForms.contains(heard) }
        return false
    }

    /// Splits free text (a transcription) into normalized words.
    static func words(in text: String) -> [String] {
        heardTokens(text).map(\.key)
    }

    /// The recognizer writes clock times in digits ("8:00", "8.15 Uhr") although the learner
    /// says them in words: "8:00" → "acht" "uhr", "8:15" → "acht" "uhr" "fünfzehn".
    static func expandClockTime(_ token: String) -> [String]? {
        let core = token.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: ":.")))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let match = core.wholeMatch(of: /(\d{1,2})[:.](\d{2})/),
              let hour = Int(match.1), let minute = Int(match.2), hour <= 24, minute < 60
        else { return nil }
        return [spellOut(hour), "uhr"] + (minute == 0 ? [] : [spellOut(minute)])
    }

    /// Symbols the recognizer writes for words the learner says (`20 €` for "zwanzig Euro").
    /// They become separate words before tokenizing, on both sides of a comparison.
    static let symbolWords: [(symbol: String, word: String)] = [
        ("€", "Euro"), ("$", "Dollar"), ("£", "Pfund"), ("%", "Prozent"), ("°", "Grad"), ("&", "und"),
    ]

    private static func expandSymbols(_ text: String) -> String {
        // Prices: "2,80 €" / "2,80 Euro" are said "zwei Euro achtzig"; "5,00 €" is "fünf Euro".
        var text = text.replacing(/(\d+),(\d{2})\s*(€|Euro\b)/) { match in
            match.2 == "00" ? "\(match.1) Euro" : "\(match.1) Euro \(match.2)"
        }
        for (symbol, word) in symbolWords where text.contains(symbol) {
            text = text.replacingOccurrences(of: symbol, with: " \(word) ")
        }
        return text
    }

    /// Heard tokens with their original spelling (for display) and normalized key.
    private static func heardTokens(_ text: String) -> [(text: String, key: String)] {
        var result: [(text: String, key: String)] = []
        for raw in expandSymbols(text).split(whereSeparator: \.isWhitespace).map(String.init) {
            if let expanded = expandClockTime(raw) {
                // A following "Uhr" ("8:00 Uhr") is already part of the expansion.
                result += expanded.map { (text: raw, key: $0) }
                continue
            }
            let key = normalize(raw)
            if key == "uhr", let previous = result.last, expandClockTime(previous.text) != nil { continue }
            if !key.isEmpty { result.append((raw, key)) }
        }
        return result
    }

    // MARK: - Alignment

    /// Aligns `heard` against target tokens. Tokens that normalize to nothing (punctuation) are
    /// not part of the result. Target words whose key is in `names` are foreign names: a run of
    /// them matches any 1 to 2×(run length) heard words (DESIGN.md §3.4), except words of the
    /// sentence itself, which keeps a run from taking over a neighbor's word.
    static func align(target tokens: [String], heard: String, names: Set<String> = []) -> Alignment {
        let target: [(index: Int, text: String, key: String)] = tokens.enumerated().compactMap { index, token in
            let key = normalize(token)
            return key.isEmpty ? nil : (index, token, key)
        }
        // Keep the heard words' original spelling for display.
        let heardTokens = heardTokens(heard)

        // Alignment units: a single word, or a run of consecutive foreign names.
        var units: [(range: Range<Int>, isName: Bool)] = []
        var start = 0
        while start < target.count {
            var end = start + 1
            let isName = names.contains(target[start].key)
            if isName {
                while end < target.count, names.contains(target[end].key) { end += 1 }
            }
            units.append((start..<end, isName))
            start = end
        }

        let n = units.count, m = heardTokens.count
        let sentenceWords = Set(target.map(\.key)).subtracting(names)
        // Heard words a run of names may stand for.
        func nameLengths(_ u: Int, from j: Int) -> Range<Int> {
            var longest = 0
            while longest < min(2 * units[u].range.count, m - j),
                  !sentenceWords.contains(heardTokens[j + longest].key) { longest += 1 }
            return 1..<longest + 1
        }
        // cost[u][j] = edit distance between units[u...] and heard[j...]; a missing unit costs
        // one per word.
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for u in stride(from: n, through: 0, by: -1) {
            for j in stride(from: m, through: 0, by: -1) {
                if u == n { cost[u][j] = m - j; continue }
                let missing = cost[u + 1][j] + units[u].range.count
                if j == m { cost[u][j] = missing; continue }
                var best = min(missing, cost[u][j + 1] + 1)  // unit missing / extra heard word
                if units[u].isName {
                    for k in nameLengths(u, from: j) { best = min(best, cost[u + 1][j + k]) }
                } else {
                    let same = matches(target[units[u].range.lowerBound].key, heardTokens[j].key)
                    best = min(best, cost[u + 1][j + 1] + (same ? 0 : 1))  // match / substitution
                }
                cost[u][j] = best
            }
        }

        var words: [Alignment.Word] = []
        var extra: [String] = []
        var u = 0, j = 0
        traceback: while u < n || j < m {
            if u < n, j < m {
                let range = units[u].range
                if units[u].isName {
                    for k in nameLengths(u, from: j) where cost[u][j] == cost[u + 1][j + k] {
                        let said = heardTokens[j..<j + k]
                        let exact = said.map(\.key) == target[range].map(\.key)
                        let heardText = said.map(\.text).joined(separator: " ")
                        for t in range {
                            let status: Alignment.Status = exact ? .match
                                : .name(heard: t == range.upperBound - 1 ? heardText : nil)
                            words.append(.init(index: target[t].index, text: target[t].text, status: status))
                        }
                        u += 1; j += k
                        continue traceback
                    }
                } else {
                    let word = target[range.lowerBound]
                    let same = matches(word.key, heardTokens[j].key)
                    if cost[u][j] == cost[u + 1][j + 1] + (same ? 0 : 1) {
                        let status: Alignment.Status = same ? .match : .substituted(heard: heardTokens[j].text)
                        words.append(.init(index: word.index, text: word.text, status: status))
                        u += 1; j += 1
                        continue
                    }
                }
            }
            if u < n, cost[u][j] == cost[u + 1][j] + units[u].range.count {
                for t in units[u].range {
                    words.append(.init(index: target[t].index, text: target[t].text, status: .missing))
                }
                u += 1
            } else {
                extra.append(heardTokens[j].text)
                j += 1
            }
        }
        return Alignment(words: words, extra: extra)
    }

    /// Aligns two texts that are tokenized the same way, digits and clock times included, so that
    /// `um 15.30 Uhr` in a sentence matches `um 15:30 Uhr` or `um fünfzehn Uhr dreißig` heard
    /// (DESIGN.md §3.4). Word indices refer to the expanded words of `expected`.
    static func align(expected: String, heard: String, names: Set<String> = []) -> Alignment {
        let expectedWords = heardTokens(expected)
        var alignment = align(target: expectedWords.map(\.key), heard: heard, names: names)
        // Show the words as written in `expected` (an expanded number shows its spelled-out word).
        for offset in alignment.words.indices {
            let word = alignment.words[offset]
            let original = expectedWords[word.index]
            if expandClockTime(original.text) == nil && !original.text.contains(where: \.isNumber) {
                alignment.words[offset].text = original.text
            }
        }
        return alignment
    }

    /// Convenience for a plain sentence: tokens are split on whitespace.
    static func align(sentence: String, heard: String) -> Alignment {
        align(target: sentence.split(whereSeparator: \.isWhitespace).map(String.init), heard: heard)
    }

    // MARK: - Private

    private static let german = Locale(identifier: "de_DE")

    private static func spellOut(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = german
        formatter.numberStyle = .spellOut
        let spelled = formatter.string(from: NSNumber(value: number)) ?? String(number)
        // Spelled-out numbers may contain soft hyphens or spaces; compare letters only.
        return normalizeLetters(spelled)
    }

    private static func normalizeLetters(_ text: String) -> String {
        let lowered = text.lowercased(with: german).replacingOccurrences(of: "ß", with: "ss")
        return String(lowered.unicodeScalars.filter { CharacterSet.letters.contains($0) }.map(Character.init))
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isNumber }
}
