import Foundation
import GRDB
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "database")

/// What the Library settings page shows (DESIGN.md §6).
nonisolated struct LibraryStats: Sendable, Equatable {
    /// Active elements by kind and level.
    var active: [ElementKind: [CEFRLevel: Int]] = [:]
    var totalElements = 0
    var practiceEvents = 0
    var batches = 0
    var seeds: [SeedImport] = []

    func activeCount(_ kind: ElementKind, _ level: CEFRLevel) -> Int {
        active[kind]?[level] ?? 0
    }
}

/// Clearing data (DESIGN.md §2.6).
nonisolated extension AppDatabase {
    /// Number of backups kept in `Backups/`.
    static let keptBackups = 5

    func libraryStats() async throws -> LibraryStats {
        try await writer.read { db in
            var stats = LibraryStats()
            let rows = try Row.fetchAll(db, sql: """
                SELECT kind, level, COUNT(*) AS n FROM element WHERE status = 'active' GROUP BY kind, level
                """)
            for row in rows {
                guard let kind = ElementKind(rawValue: row["kind"]), let level = CEFRLevel(rawValue: row["level"]) else { continue }
                stats.active[kind, default: [:]][level] = row["n"]
            }
            stats.totalElements = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM element") ?? 0
            stats.practiceEvents = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM practice_event") ?? 0
            stats.batches = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM batch") ?? 0
            stats.seeds = try SeedImport.order(Column("imported_at").desc, Column("seed_id")).fetchAll(db)
            return stats
        }
    }

    /// Deletes the user layer: events, mastery and batches (sentences cascade). Content stays.
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
            for table in ["element_link", "word_form", "vocab_detail", "grammar_detail", "pattern_detail", "element", "seed_import"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
        logger.info("Database reset")
    }

    private static func deleteUserLayer(_ db: Database) throws {
        for table in ["practice_event", "mastery", "sentence_element", "sentence", "batch"] {
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
