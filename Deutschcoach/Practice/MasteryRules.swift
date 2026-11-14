import Foundation

/// Mastery rules (DESIGN.md §3.5). The level of one (element, dimension) is a pure function of its
/// event outcomes in order, so all mastery can be recomputed from `practice_event` after the rules
/// change.
nonisolated enum MasteryRules {
    static let minLevel = 1
    static let maxLevel = 5
    /// Consecutive passes needed to go up one level.
    static let passesToLevelUp = 3

    /// - `fail`: down one level, streak reset.
    /// - `pass`: streak + 1; at `passesToLevelUp`, up one level and the streak starts over.
    /// - `not_attempted`: no change, does not break the streak.
    static func level(after outcomes: some Sequence<PracticeOutcome>) -> Int {
        var level = minLevel
        var streak = 0
        for outcome in outcomes {
            switch outcome {
            case .fail:
                level = max(minLevel, level - 1)
                streak = 0
            case .pass:
                streak += 1
                if streak == passesToLevelUp {
                    level = min(maxLevel, level + 1)
                    streak = 0
                }
            case .notAttempted:
                break
            }
        }
        return level
    }
}
