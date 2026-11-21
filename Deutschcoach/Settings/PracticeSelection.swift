import Foundation

/// The libraries (seed ids) the user practices, checked in Settings › Library (DESIGN.md §3.2).
/// Stored in UserDefaults; `resolve` keeps it valid against the imported libraries.
nonisolated enum PracticeSelection {
    static let defaultsKey = "practiceSeeds"
    /// The former user level, read once to check its libraries and then removed.
    static let legacyLevelKey = "userLevel"

    static var stored: [String]? {
        get { UserDefaults.standard.stringArray(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static var legacyLevel: String? {
        get { UserDefaults.standard.string(forKey: legacyLevelKey) }
        set { UserDefaults.standard.set(newValue, forKey: legacyLevelKey) }
    }

    /// The selection to use with `seeds` imported, in the order of `seeds`:
    /// the stored ids that still exist; otherwise the bundled libraries of the former user level;
    /// otherwise the bundled library of the lowest level (any library when none is bundled).
    /// Empty only when nothing is imported.
    static func resolve(stored: [String]?, legacyLevel: String?, seeds: [SeedImport]) -> [String] {
        let ordered = sorted(seeds)
        if let stored {
            let kept = ordered.map(\.seedId).filter(stored.contains)
            if !kept.isEmpty { return kept }
        }
        let bundled = ordered.filter { $0.origin == .bundled }
        if let legacyLevel {
            let ofLevel = bundled.filter { $0.level.rawValue == legacyLevel }.map(\.seedId)
            if !ofLevel.isEmpty { return ofLevel }
        }
        return [(bundled.first ?? ordered.first)?.seedId].compactMap { $0 }
    }

    /// Libraries in display order: by level, then id.
    static func sorted(_ seeds: [SeedImport]) -> [SeedImport] {
        seeds.sorted { ($0.level.rawValue, $0.seedId) < ($1.level.rawValue, $1.seedId) }
    }
}
