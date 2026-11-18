import Foundation
import GRDB
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "database")

/// What the Library settings page shows (DESIGN.md §6).
nonisolated struct LibraryStats: Sendable, Equatable {
    /// Active entries and sentences by level.
    var entries: [CEFRLevel: Int] = [:]
    var sentences: [CEFRLevel: Int] = [:]
    var practiceEvents = 0
    var sessions = 0
    var seeds: [SeedImport] = []

    var totalSentences: Int { sentences.values.reduce(0, +) }
}

/// Clearing data (DESIGN.md §2.6).
nonisolated extension AppDatabase {
    /// Number of backups kept in `Backups/`.
    static let keptBackups = 5

    func libraryStats() async throws -> LibraryStats {
        try await writer.read { db in
            var stats = LibraryStats()
            func counts(_ table: String) throws -> [CEFRLevel: Int] {
                var result: [CEFRLevel: Int] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT level, COUNT(*) AS n FROM \(table) WHERE status = 'active' GROUP BY level") {
                    guard let level = CEFRLevel(rawValue: row["level"]) else { continue }
                    result[level] = row["n"]
                }
                return result
            }
            stats.entries = try counts("entry")
            stats.sentences = try counts("sentence")
            stats.practiceEvents = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM practice_event") ?? 0
            stats.sessions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session") ?? 0
            stats.seeds = try SeedImport.order(Column("seed_id")).fetchAll(db)
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
