import Foundation
import GRDB

/// Owns the SQLite connection and the schema migrations (DESIGN.md §2).
///
/// The app target defaults to `MainActor` isolation, so this type is explicitly
/// `nonisolated`: GRDB serializes database access itself, and the writer is `Sendable`.
nonisolated final class AppDatabase: Sendable {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Never enable `eraseDatabaseOnSchemaChange`: it would wipe user data.
        migrator.registerMigration("v1") { db in
            try db.execute(sql: Schema.v1)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: Schema.v2)
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: Schema.v3)
        }
        migrator.registerMigration("v4") { db in
            try db.execute(sql: Schema.v4)
            // progress is a cache of the events under the current rules (DESIGN.md §3.5).
            try PracticeStore.recomputeAllProgress(db)
        }
        return migrator
    }
}

// MARK: - Factories

nonisolated extension AppDatabase {
    /// The on-disk database inside the app's sandbox container:
    /// `~/Library/Containers/<bundle id>/Data/Library/Application Support/Deutschcoach/db.sqlite`
    static func openShared() throws -> AppDatabase {
        let fileManager = FileManager.default
        let directory = try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Deutschcoach", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        // DatabasePool uses WAL mode, so reads can run concurrently with writes
        // (e.g. the seed import runs off the main actor).
        let pool = try DatabasePool(path: url.path(percentEncoded: false))
        return try AppDatabase(pool)
    }

    /// An in-memory database, for tests and previews.
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    var path: String { writer.path }
}
