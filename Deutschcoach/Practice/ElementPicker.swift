import Foundation
import GRDB

/// Picks the target elements of a batch and assigns each sentence its mode (DESIGN.md §3.2).
///
/// Each sentence gets 1–3 vocabulary items, 1 grammar point and sometimes 1 pattern, drawn by
/// weighted random. The first vocabulary item drawn is the primary target; its mastery decides
/// the mode.
nonisolated struct ElementPicker {
    /// Everything about one candidate element that selection needs.
    struct Candidate: Sendable, Equatable {
        var id: Int64
        var kind: ElementKind
        var title: String
        var sense: String?
        var pronunciation = MasteryRules.minLevel
        var recall = MasteryRules.minLevel
        /// Latest `last_seen_at` of both dimensions.
        var lastSeen: Int64?
        var prerequisites: [Int64] = []

        /// The mastery that drives the weight: grammar points only have `recall`; others use
        /// the weaker dimension.
        var weightMastery: Int {
            kind == .grammar ? recall : min(pronunciation, recall)
        }

        /// The mastery a prerequisite must reach: grammar points use `recall`; others the
        /// stronger dimension.
        var prerequisiteMastery: Int {
            kind == .grammar ? recall : max(pronunciation, recall)
        }
    }

    static let prerequisiteThreshold = 2
    /// Staleness is capped at this many days; never-practiced elements count as this.
    static let maxStaleDays = 14.0
    static let patternChance = 0.3

    var count = 10
    var nativeLang = NativeLanguage.current
    /// Fixed until the settings screen offers a choice (§3.2).
    var userLevel = CEFRLevel.a1
    var now: Date = Date()

    // MARK: - Database

    func makeRequest(from db: Database) throws -> GenerationRequest {
        var rng = SystemRandomNumberGenerator()
        return makeRequest(candidates: try Self.loadCandidates(upTo: userLevel, from: db), using: &rng)
    }

    /// Active elements at or below `level`, with their mastery and prerequisites.
    static func loadCandidates(upTo level: CEFRLevel, from db: Database) throws -> [Candidate] {
        let levels = CEFRLevel.allCases.prefix { $0 != level } + [level]
        let placeholders = levels.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.id, e.kind, e.title, v.sense FROM element e
            LEFT JOIN vocab_detail v ON v.element_id = e.id
            WHERE e.status = 'active' AND e.level IN (\(placeholders))
            ORDER BY e.id
            """, arguments: StatementArguments(levels.map(\.rawValue)))
        var candidates: [Int64: Candidate] = [:]
        var order: [Int64] = []
        for row in rows {
            guard let kind = ElementKind(rawValue: row["kind"]) else { continue }
            let id: Int64 = row["id"]
            candidates[id] = Candidate(id: id, kind: kind, title: row["title"], sense: row["sense"])
            order.append(id)
        }
        for mastery in try Mastery.fetchAll(db) where candidates[mastery.elementId] != nil {
            switch mastery.dimension {
            case .pronunciation: candidates[mastery.elementId]!.pronunciation = mastery.level
            case .recall: candidates[mastery.elementId]!.recall = mastery.level
            }
            if let seen = mastery.lastSeenAt {
                candidates[mastery.elementId]!.lastSeen = max(candidates[mastery.elementId]!.lastSeen ?? seen, seen)
            }
        }
        for link in try ElementLink.filter(Column("kind") == ElementLinkKind.prerequisite.rawValue).fetchAll(db)
        where candidates[link.fromId] != nil {
            candidates[link.fromId]!.prerequisites.append(link.toId)
        }
        return order.map { candidates[$0]! }
    }

    // MARK: - Selection

    func makeRequest(candidates: [Candidate], using rng: inout some RandomNumberGenerator) -> GenerationRequest {
        let byId = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let eligible = Set(candidates.filter { candidate in
            candidate.prerequisites.allSatisfy { id in
                // A prerequisite outside the candidates (higher level, retired) does not block.
                guard let prerequisite = byId[id] else { return true }
                return prerequisite.prerequisiteMastery >= Self.prerequisiteThreshold
            }
        }.map(\.id))
        let nowSeconds = now.timeIntervalSince1970

        var usedInBatch: Set<Int64> = []
        var sentences: [SentenceRequest] = []
        for position in 1...count {
            var picked: [Candidate] = []
            func draw(_ kind: ElementKind) {
                let pool = candidates.filter { $0.kind == kind && !picked.contains($0) }
                // §3.2: relax the prerequisite filter first, then allow repeats within the batch.
                let tiers = [
                    pool.filter { eligible.contains($0.id) && !usedInBatch.contains($0.id) },
                    pool.filter { !usedInBatch.contains($0.id) },
                    pool.filter { eligible.contains($0.id) },
                    pool,
                ]
                guard let tier = tiers.first(where: { !$0.isEmpty }) else { return }
                let weights = tier.map { Self.weight(of: $0, now: nowSeconds, using: &rng) }
                let chosen = tier[Self.weightedIndex(weights, using: &rng)]
                picked.append(chosen)
                usedInBatch.insert(chosen.id)
            }

            draw(.vocab)  // the primary target
            for _ in 0..<Int.random(in: 0...2, using: &rng) { draw(.vocab) }
            draw(.grammar)
            if Double.random(in: 0..<1, using: &rng) < Self.patternChance { draw(.pattern) }

            let primary = picked.first { $0.kind == .vocab }
            sentences.append(SentenceRequest(
                position: position,
                mode: primary.map { Self.mode(pronunciation: $0.pronunciation, recall: $0.recall) } ?? .shadow,
                targets: picked.map { GenerationTarget(elementId: $0.id, kind: $0.kind, title: $0.title, sense: $0.sense) }
            ))
        }
        return GenerationRequest(nativeLang: nativeLang, userLevel: userLevel, sentences: sentences)
    }

    /// §3.2 mode table, by the primary target's mastery.
    static func mode(pronunciation: Int, recall: Int) -> SentenceMode {
        if pronunciation < 3 { return .shadow }
        if recall < 3 { return .cloze }
        return .recall
    }

    /// `(6 − mastery)² × (1 + min(days since last practice, 14) / 7) × jitter(0.8–1.2)`.
    static func weight(of candidate: Candidate, now: TimeInterval, using rng: inout some RandomNumberGenerator) -> Double {
        let mastery = Double(MasteryRules.maxLevel + 1 - candidate.weightMastery)
        let days = candidate.lastSeen.map { max(0, (now - TimeInterval($0)) / 86_400) } ?? maxStaleDays
        let staleness = 1 + min(days, maxStaleDays) / 7
        return mastery * mastery * staleness * Double.random(in: 0.8...1.2, using: &rng)
    }

    private static func weightedIndex(_ weights: [Double], using rng: inout some RandomNumberGenerator) -> Int {
        let total = weights.reduce(0, +)
        var point = Double.random(in: 0..<total, using: &rng)
        for (index, weight) in weights.enumerated() {
            if point < weight { return index }
            point -= weight
        }
        return weights.count - 1
    }
}
