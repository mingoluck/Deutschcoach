import Foundation

/// Chooses the cloze blanks of a sentence (DESIGN.md §3.3): 1–3 tokens from the target elements'
/// tokens, at most one per target, punctuation excluded.
nonisolated enum ClozeBlanks {
    static let maxBlanks = 3

    /// `targets` in request order (the primary vocabulary item first). Returns sorted indices.
    static func choose(
        targets: [TargetTokens],
        words: [AnnotationToken],
        using rng: inout some RandomNumberGenerator
    ) -> [Int] {
        var blanks: [Int] = []
        for target in targets where blanks.count < maxBlanks {
            let options = target.tokens.filter { index in
                words.indices.contains(index) && !words[index].isPunctuation && !blanks.contains(index)
            }
            if let index = options.randomElement(using: &rng) { blanks.append(index) }
        }
        return blanks.sorted()
    }
}
