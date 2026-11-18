import Foundation

/// The learner's level, chosen in Settings (DESIGN.md §3.2). Practice uses only that level's
/// sentences.
nonisolated enum UserLevel {
    static let defaultsKey = "userLevel"

    static var current: CEFRLevel {
        get {
            let stored = UserDefaults.standard.string(forKey: defaultsKey).flatMap(CEFRLevel.init(rawValue:))
            return stored.flatMap { CEFRLevel.practiceLevels.contains($0) ? $0 : nil } ?? .a1
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}
