import Foundation
import GRDB

/// Picks the sentences of a session and their modes (DESIGN.md §3.2). The picking is a pure
/// function of the candidates and a random source, so it can be tested without a database.
nonisolated struct SessionBuilder {
    static let sessionSize = 10
    /// At most this many never-practiced sentences per session (initial value, adjustable).
    static let newWindow = 5
    /// Days since last practice stop adding weight after this.
    static let maxStaleDays = 14.0

    struct EntryRef: Sendable, Equatable {
        var id: Int64
        /// Austrian or Swiss usage.
        var regional: Bool
    }

    struct Candidate: Sendable, Equatable {
        var sentenceId: Int64
        var entries: [EntryRef]
        /// The `progress` level, nil for a new sentence.
        var progress: Int?
        /// Unix time in seconds of the last event, nil if never practiced.
        var lastSeenAt: Int64?

        /// New: no `progress` row yet.
        var isNew: Bool { progress == nil }
        /// The ladder level; a new sentence counts as `MasteryRules.newLevel` (§3.5).
        var level: Int { progress ?? MasteryRules.newLevel }
        var mode: SentenceMode { MasteryRules.mode(level: level) }
        /// Practiced only when at least one linked entry is common German (§3.2).
        var isPracticable: Bool { entries.contains { !$0.regional } }
    }

    struct Pick: Sendable, Equatable {
        var sentenceId: Int64
        var mode: SentenceMode
        /// Cloze: the entry whose tokens are blanked.
        var blankEntryId: Int64?
    }

    /// Active sentences of `level` with their entries and progress.
    static func loadCandidates(level: CEFRLevel, from db: Database) throws -> [Candidate] {
        var candidates: [Int64: Candidate] = [:]
        var order: [Int64] = []
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.id AS sentence_id, se.entry_id, e.region,
                   p.level, p.last_seen_at
            FROM sentence s
            JOIN sentence_entry se ON se.sentence_id = s.id
            JOIN entry e ON e.id = se.entry_id
            LEFT JOIN progress p ON p.sentence_id = s.id
            WHERE s.level = ? AND s.status = 'active'
            ORDER BY s.sort, se.entry_id
            """, arguments: [level.rawValue])
        for row in rows {
            let id: Int64 = row["sentence_id"]
            let entry = EntryRef(id: row["entry_id"], regional: (row["region"] as String?) != nil)
            if candidates[id] == nil {
                candidates[id] = Candidate(sentenceId: id, entries: [], progress: row["level"], lastSeenAt: row["last_seen_at"])
                order.append(id)
            }
            candidates[id]?.entries.append(entry)
        }
        return order.compactMap { candidates[$0] }
    }

    /// Base weight by ladder level (initial values, adjustable): highest on the first step of each
    /// mode (1, 3, 5), middle on the second (2, 4, 6, and new sentences), lowest once mastered (7).
    static func baseWeight(level: Int) -> Double {
        if level >= MasteryRules.masteredLevel { return 1 }
        return level % 2 == 1 ? 9 : 4
    }

    /// Weight = base(level) × (1 + min(days since last practice, 14) / 7) × jitter(0.8–1.2).
    /// Never-practiced sentences count as 14 days.
    static func weight(of candidate: Candidate, now: Date, using rng: inout some RandomNumberGenerator) -> Double {
        let days = candidate.lastSeenAt.map { max(0, now.timeIntervalSince1970 - Double($0)) / 86_400 } ?? maxStaleDays
        let base = baseWeight(level: candidate.level)
        return base * (1 + min(days, maxStaleDays) / 7) * Double.random(in: 0.8...1.2, using: &rng)
    }

    /// Up to `sessionSize` sentences, no sentence twice. Stages: at most `newWindow` new
    /// sentences and one sentence per entry; then any number of new ones; then several
    /// sentences of one entry. A session may have fewer than 10 sentences when the level has
    /// too few.
    static func pick(from candidates: [Candidate], now: Date = Date(), using rng: inout some RandomNumberGenerator) -> [Pick] {
        let pool = candidates.filter(\.isPracticable)
        var chosen: [Candidate] = []
        var usedEntries: Set<Int64> = []
        var newCount = 0

        for stage in 0..<3 {
            while chosen.count < sessionSize {
                let admissible = pool.filter { candidate in
                    if chosen.contains(where: { $0.sentenceId == candidate.sentenceId }) { return false }
                    if stage == 0, candidate.isNew, newCount >= newWindow { return false }
                    if stage < 2, candidate.entries.contains(where: { usedEntries.contains($0.id) }) { return false }
                    return true
                }
                guard !admissible.isEmpty else { break }
                let weights = admissible.map { weight(of: $0, now: now, using: &rng) }
                let next = admissible[weightedIndex(weights, using: &rng)]
                chosen.append(next)
                usedEntries.formUnion(next.entries.map(\.id))
                if next.isNew { newCount += 1 }
            }
        }

        return chosen.map { candidate in
            let mode = candidate.mode
            var blank: Int64?
            if mode == .cloze {
                let common = candidate.entries.filter { !$0.regional }
                blank = (common.isEmpty ? candidate.entries : common).randomElement(using: &rng)?.id
            }
            return Pick(sentenceId: candidate.sentenceId, mode: mode, blankEntryId: blank)
        }
    }

    private static func weightedIndex(_ weights: [Double], using rng: inout some RandomNumberGenerator) -> Int {
        let total = weights.reduce(0, +)
        var point = Double.random(in: 0..<max(total, .leastNonzeroMagnitude), using: &rng)
        for (index, weight) in weights.enumerated() {
            if point < weight { return index }
            point -= weight
        }
        return weights.count - 1
    }
}
