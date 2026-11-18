import Foundation

/// Word-level alignment of a recognized utterance against a target sentence (DESIGN.md §3.4).
nonisolated struct Alignment: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case match
        /// The word was read as something else.
        case substituted(heard: String)
        /// The word was not heard at all.
        case missing
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

    var allMatched: Bool { words.allSatisfy { $0.status == .match } }
    var matchedCount: Int { words.filter { $0.status == .match }.count }
}

nonisolated enum WordAligner {
    // MARK: - Normalization

    /// Normalizes a single token: lowercase, ß → ss, punctuation removed, digits spelled out in
    /// German (`3` → `drei`). Returns an empty string for tokens without letters or digits.
    static func normalize(_ token: String) -> String {
        let lowered = token.lowercased(with: german).replacingOccurrences(of: "ß", with: "ss")
        let kept = String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        if !kept.isEmpty, kept.allSatisfy(\.isASCIIDigit), let number = Int(kept) {
            return spellOut(number)
        }
        return kept
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
        var text = text
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
    /// not part of the result.
    static func align(target tokens: [String], heard: String) -> Alignment {
        let target: [(index: Int, text: String, key: String)] = tokens.enumerated().compactMap { index, token in
            let key = normalize(token)
            return key.isEmpty ? nil : (index, token, key)
        }
        // Keep the heard words' original spelling for display.
        let heardTokens = heardTokens(heard)

        let n = target.count, m = heardTokens.count
        // cost[i][j] = edit distance between target[i...] and heard[j...]
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n, through: 0, by: -1) {
            for j in stride(from: m, through: 0, by: -1) {
                if i == n { cost[i][j] = m - j; continue }
                if j == m { cost[i][j] = n - i; continue }
                let same = target[i].key == heardTokens[j].key
                cost[i][j] = min(
                    cost[i + 1][j + 1] + (same ? 0 : 1),  // match / substitution
                    cost[i + 1][j] + 1,                    // target word missing
                    cost[i][j + 1] + 1                     // extra heard word
                )
            }
        }

        var words: [Alignment.Word] = []
        var extra: [String] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m {
                let same = target[i].key == heardTokens[j].key
                if cost[i][j] == cost[i + 1][j + 1] + (same ? 0 : 1) {
                    let status: Alignment.Status = same ? .match : .substituted(heard: heardTokens[j].text)
                    words.append(.init(index: target[i].index, text: target[i].text, status: status))
                    i += 1; j += 1
                    continue
                }
            }
            if i < n, cost[i][j] == cost[i + 1][j] + 1 {
                words.append(.init(index: target[i].index, text: target[i].text, status: .missing))
                i += 1
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
    static func align(expected: String, heard: String) -> Alignment {
        let expectedWords = heardTokens(expected)
        var alignment = align(target: expectedWords.map(\.key), heard: heard)
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
