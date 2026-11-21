import Foundation

/// Mastery rules (DESIGN.md §3.5): one ladder per sentence, levels 1–7, whose level decides the
/// mode. The level is a pure function of the sentence's event outcomes in order, so all progress
/// can be recomputed from `practice_event` after the rules change.
nonisolated enum MasteryRules {
    static let minLevel = 1
    static let maxLevel = 7
    /// A sentence without a `progress` row is at this level.
    static let newLevel = 2
    /// The top of the ladder: the sentence is mastered.
    static let masteredLevel = maxLevel

    /// Starts at `newLevel`. `pass`: up one level; `fail`: down one level, also across modes;
    /// `not_attempted`: no change.
    static func level(after outcomes: some Sequence<PracticeOutcome>) -> Int {
        var level = newLevel
        for outcome in outcomes {
            switch outcome {
            case .pass: level = min(maxLevel, level + 1)
            case .fail: level = max(minLevel, level - 1)
            case .notAttempted: break
            }
        }
        return level
    }

    /// 1–2 shadowing, 3–4 cloze, 5–7 translation (§3.2).
    static func mode(level: Int) -> SentenceMode {
        switch level {
        case ...2: .shadow
        case 3...4: .cloze
        default: .recall
        }
    }
}
