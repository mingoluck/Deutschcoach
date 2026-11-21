import Foundation
import GRDB
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "database")

/// The active sentences of one library by level of the mastery ladder (DESIGN.md §3.5, §6).
nonisolated struct LibraryProgress: Sendable, Equatable {
    var seedId: String
    var title: String
    var level: CEFRLevel
    /// No `progress` row yet.
    var new = 0
    /// Practiced sentences by ladder level; index 0 is unused.
    var byLevel = Array(repeating: 0, count: MasteryRules.maxLevel + 1)

    var practiced: Int { byLevel.reduce(0, +) }
    var total: Int { new + practiced }

    /// Practiced sentences at `level` or above.
    func reached(_ level: Int) -> Int {
        byLevel[max(level, MasteryRules.minLevel)...].reduce(0, +)
    }

    /// Level 7.
    var mastered: Int { reached(MasteryRules.masteredLevel) }

    /// `count` as a share of all active sentences, 0 for an empty library.
    func share(_ count: Int) -> Double {
        total == 0 ? 0 : Double(count) / Double(total)
    }

    mutating func add(_ count: Int, atLevel level: Int?) {
        guard let level, byLevel.indices.contains(level), level >= MasteryRules.minLevel else { new += count; return }
        byLevel[level] += count
    }

    /// The progress of every imported library, or only of `seedId`, keyed by seed id.
    static func fetch(seedId: String? = nil, _ db: Database) throws -> [String: LibraryProgress] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.seed_id, i.title, i.level, p.level AS ladder, COUNT(s.id) AS n
            FROM seed_import i
            LEFT JOIN sentence s ON s.seed_id = i.seed_id AND s.status = 'active'
            LEFT JOIN progress p ON p.sentence_id = s.id
            WHERE ?1 IS NULL OR i.seed_id = ?1
            GROUP BY i.seed_id, p.level
            """, arguments: [seedId])
        var result: [String: LibraryProgress] = [:]
        for row in rows {
            let id: String = row["seed_id"]
            guard let level = CEFRLevel(rawValue: row["level"]) else { continue }
            result[id, default: LibraryProgress(seedId: id, title: row["title"], level: level)]
                .add(row["n"], atLevel: row["ladder"])
        }
        return result
    }
}

/// What the Library settings page shows (DESIGN.md §6).
nonisolated struct LibraryStats: Sendable, Equatable {
    /// Imported libraries in display order (by level, then id).
    var seeds: [SeedImport] = []
    /// Progress by seed id.
    var progress: [String: LibraryProgress] = [:]
    var practiceEvents = 0
    var sessions = 0

    var totalSentences: Int { progress.values.reduce(0) { $0 + $1.total } }
}

/// Clearing data (DESIGN.md §2.6).
nonisolated extension AppDatabase {
    /// Number of backups kept in `Backups/`.
    static let keptBackups = 5

    func libraryStats() async throws -> LibraryStats {
        try await writer.read { db in
            var stats = LibraryStats()
            stats.seeds = PracticeSelection.sorted(try SeedImport.fetchAll(db))
            stats.progress = try LibraryProgress.fetch(db)
            stats.practiceEvents = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM practice_event") ?? 0
            stats.sessions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session") ?? 0
            return stats
        }
    }

    /// Deletes the user layer: events, progress and sessions (items cascade). Content stays.
    func clearPracticeRecords() async throws {
        try await writer.write { db in
            try Self.deleteUserLayer(db)
        }
        logger.info("Practice records cleared")
    }

    /// Deletes every row of every table: the user layer first, then the content layer.
    /// The schema and the migration history stay.
    func resetAllData() async throws {
        try await writer.write { db in
            try Self.deleteUserLayer(db)
            for table in ["sentence_entry", "sentence", "entry", "seed_import"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
        logger.info("Database reset")
    }

    private static func deleteUserLayer(_ db: Database) throws {
        for table in ["practice_event", "progress", "session_item", "session"] {
            try db.execute(sql: "DELETE FROM \(table)")
        }
    }

    /// Copies the whole database to `Backups/db-<yyyyMMdd-HHmmss>.sqlite` next to the database
    /// file and keeps the newest `keptBackups`. Returns `nil` for an in-memory database.
    @discardableResult
    func backup(now: Date = Date()) throws -> URL? {
        guard !path.isEmpty, path != ":memory:", FileManager.default.fileExists(atPath: path) else { return nil }
        let directory = URL(filePath: path).deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appending(path: "db-\(formatter.string(from: now)).sqlite")
        try? FileManager.default.removeItem(at: url)

        let destination = try DatabaseQueue(path: url.path(percentEncoded: false))
        try writer.backup(to: destination)
        try destination.close()
        logger.info("Backup written to \(url.path(percentEncoded: false), privacy: .public)")

        try Self.pruneBackups(in: directory)
        return url
    }

    private static func pruneBackups(in directory: URL) throws {
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasPrefix("db-") && $0.hasSuffix(".sqlite") }
            .sorted(by: >)  // the timestamp in the name sorts chronologically
        for name in backups.dropFirst(keptBackups) {
            try FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}
