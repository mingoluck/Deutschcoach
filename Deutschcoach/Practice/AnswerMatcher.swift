import Foundation

/// Scores a spoken answer by exact match after normalization (DESIGN.md §3.4), the same rule in
/// all three modes.
nonisolated enum AnswerMatcher {
    struct Result: Sendable, Equatable {
        var outcome: PracticeOutcome
        var reason: NotAttemptedReason?
        /// The comparison shown on the answer; nil when nothing was heard or the user skipped.
        var alignment: Alignment?

        /// Indices of the words of the compared reading that did not match.
        var mismatched: [Int] {
            alignment?.words.filter { !$0.status.isAccepted }.map(\.index) ?? []
        }
    }

    /// `heard` is the final transcription, nil when skipped. `names` are the sentence's foreign
    /// names (`SentenceAnnotation.foreignNames`), which are not checked.
    static func score(de: String, spoken: String?, heard: String?, skipped: Bool = false,
                      names: Set<String> = []) -> Result {
        if skipped { return Result(outcome: .notAttempted, reason: .skipped) }
        guard let heard, hasSpeech(heard) else { return Result(outcome: .notAttempted, reason: .noSpeech) }

        // The answer may match the reading in words (`spoken`) or the written form with digits
        // (`de`); digits are expanded the same way on both sides.
        let readings = [spoken, de].compactMap { $0 }
        let alignments = readings.map { WordAligner.align(expected: $0, heard: heard, names: names) }
        if let exact = alignments.first(where: isExact) {
            return Result(outcome: .pass, alignment: exact)
        }
        let best = alignments.min { errors($0) < errors($1) }
        return Result(outcome: .fail, alignment: best)
    }

    static func hasSpeech(_ heard: String) -> Bool {
        !WordAligner.words(in: heard).isEmpty
    }

    static func isExact(_ alignment: Alignment) -> Bool {
        alignment.allMatched && alignment.extra.isEmpty
    }

    private static func errors(_ alignment: Alignment) -> Int {
        alignment.words.count - alignment.matchedCount + alignment.extra.count
    }
}

/// An answer and its score, as shown on the result step and in the history.
nonisolated struct ScoredAnswer: Sendable, Equatable {
    var heard: String?
    var result: AnswerMatcher.Result
}
