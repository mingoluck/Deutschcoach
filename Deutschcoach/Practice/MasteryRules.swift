import Foundation

/// Mastery rules (DESIGN.md §3.5). The level of one (sentence, dimension) is a pure function of its
/// event outcomes in order, so all progress can be recomputed from `practice_event` after the
/// rules change.
nonisolated enum MasteryRules {
    static let minLevel = 1
    static let maxLevel = 5
    /// Pronunciation and recall levels from which the next mode starts (§3.2).
    static let modeThreshold = 3

    /// `pass`: up one level; `fail`: down one level; `not_attempted`: no change.
    static func level(after outcomes: some Sequence<PracticeOutcome>) -> Int {
        var level = minLevel
        for outcome in outcomes {
            switch outcome {
            case .pass: level = min(maxLevel, level + 1)
            case .fail: level = max(minLevel, level - 1)
            case .notAttempted: break
            }
        }
        return level
    }

    /// The mode by the sentence's own mastery (§3.2).
    static func mode(pronunciation: Int, recall: Int) -> SentenceMode {
        if pronunciation < modeThreshold { return .shadow }
        if recall < modeThreshold { return .cloze }
        return .recall
    }

    /// The mastery dimension a mode affects (§3.3).
    static func dimension(of mode: SentenceMode) -> MasteryDimension {
        mode == .shadow ? .pronunciation : .recall
    }
}
