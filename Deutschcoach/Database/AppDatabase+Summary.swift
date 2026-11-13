import Foundation
import GRDB

/// Row counts of the content layer, used by the M1 debug screen and tests.
nonisolated struct ContentSummary: Sendable, Equatable {
    var elementsByKind: [ElementKind: Int] = [:]
    var wordForms = 0
    var links = 0

    var totalElements: Int { elementsByKind.values.reduce(0, +) }
}

nonisolated extension AppDatabase {
    func contentSummary() async throws -> ContentSummary {
        try await writer.read { db in
            var summary = ContentSummary()
            let rows = try Row.fetchAll(db, sql: "SELECT kind, COUNT(*) AS n FROM element GROUP BY kind")
            for row in rows {
                if let kind = ElementKind(rawValue: row["kind"]) {
                    summary.elementsByKind[kind] = row["n"]
                }
            }
            summary.wordForms = try WordForm.fetchCount(db)
            summary.links = try ElementLink.fetchCount(db)
            return summary
        }
    }
}
