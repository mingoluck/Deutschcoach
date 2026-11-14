import Foundation
import GRDB

/// TEMPORARY (M4): picks random targets so generation can be exercised end to end.
/// The real selection — weighting by mastery, prerequisites, mode assignment (DESIGN.md §3.2) —
/// replaces this in M5.
///
/// Each sentence gets 1 grammar point, 1–3 vocabulary items and sometimes 1 pattern, avoiding
/// repeats within the batch while elements last. Every sentence is `shadow`.
nonisolated struct SimpleTargetPicker {
    var count = 10
    var nativeLang = NativeLanguage.current
    var userLevel = CEFRLevel.a1

    func makeRequest(from db: Database) throws -> GenerationRequest {
        let levels = CEFRLevel.allCases.prefix { $0 != userLevel } + [userLevel]
        let placeholders = levels.map { _ in "?" }.joined(separator: ",")
        let candidates = try Element.fetchAll(
            db,
            sql: "SELECT * FROM element WHERE status = 'active' AND level IN (\(placeholders))",
            arguments: StatementArguments(levels.map(\.rawValue))
        )
        var pools: [ElementKind: Pool] = [:]
        for kind in ElementKind.allCases {
            pools[kind] = Pool(elements: candidates.filter { $0.kind == kind })
        }
        let senses = try Dictionary(
            uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT element_id, sense FROM vocab_detail WHERE sense IS NOT NULL")
                .map { (row: Row) -> (Int64, String) in (row["element_id"], row["sense"]) }
        )

        var sentences: [SentenceRequest] = []
        for position in 1...count {
            var picked: [Element] = []
            picked += pools[.grammar]!.take(1)
            picked += pools[.vocab]!.take(Int.random(in: 1...3))
            if Int.random(in: 0..<10) < 3 { picked += pools[.pattern]!.take(1) }
            sentences.append(SentenceRequest(
                position: position,
                mode: .shadow,
                targets: picked.map { element in
                    GenerationTarget(elementId: element.id!, kind: element.kind, title: element.title, sense: senses[element.id!])
                }
            ))
        }
        return GenerationRequest(nativeLang: nativeLang, userLevel: userLevel, sentences: sentences)
    }

    /// Hands out elements in random order without repeats until the pool is used up, then refills.
    private final class Pool {
        let elements: [Element]
        var remaining: [Element] = []

        init(elements: [Element]) {
            self.elements = elements
        }

        func take(_ n: Int) -> [Element] {
            var taken: [Element] = []
            while taken.count < n, !elements.isEmpty {
                if remaining.isEmpty { remaining = elements.shuffled() }
                let next = remaining.removeLast()
                if !taken.contains(where: { $0.id == next.id }) { taken.append(next) }
                if taken.count == elements.count { break }
            }
            return taken
        }
    }
}
