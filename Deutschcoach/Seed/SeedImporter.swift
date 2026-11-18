import Foundation
import GRDB
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "seed")

/// Imports seed files into the content layer (DESIGN.md §2.5).
///
/// - Every file is validated first (§4.3); nothing is written when a file has problems.
/// - `entry` and `sentence` rows are upserted by `key` with `INSERT … ON CONFLICT(key) DO UPDATE`,
///   so ids stay stable. Never use `INSERT OR REPLACE` here: it deletes the old row, changes its
///   id and cascades the delete to dependent rows.
/// - Each imported sentence's `sentence_entry` rows are replaced; entry `parent` links are
///   resolved after all entries are upserted.
/// - Entries and sentences of the same seed that are missing from the file are retired, never
///   deleted, because user data references them.
/// - The header is recorded in `seed_import`. User-layer tables are never touched.
nonisolated enum SeedImporter {
    struct Report: Sendable, Equatable {
        var seedId: String
        var version: Int
        var entries = 0
        var sentences = 0
        var newSentences = 0
        var retiredEntries = 0
        var retiredSentences = 0
    }

    /// The file's problems; thrown as a whole so the caller can show all of them.
    struct ValidationFailed: Error, LocalizedError, Sendable {
        var issues: [SeedIssue]

        var errorDescription: String? {
            let shown = issues.prefix(5).map(\.localizedDescription)
            let more = issues.count > shown.count ? ["… and \(issues.count - shown.count) more"] : []
            return (shown + more).joined(separator: "\n")
        }
    }

    static func decode(_ data: Data) throws -> SeedFile {
        try JSONDecoder().decode(SeedFile.self, from: data)
    }

    /// Validates `file` and checks that its keys are not owned by another seed in the database.
    static func problems(of file: SeedFile, in db: Database) throws -> [SeedIssue] {
        var issues = SeedValidator.validate(file)
        let seedId = file.seed.id
        let foreignEntries = try String.fetchSet(db, sql: "SELECT key FROM entry WHERE seed_id != ?", arguments: [seedId])
        let foreignSentences = try String.fetchSet(db, sql: "SELECT key FROM sentence WHERE seed_id != ?", arguments: [seedId])
        for entry in file.entries where foreignEntries.contains(entry.key) {
            issues.append(SeedIssue(seed: seedId, key: entry.key, message: "the key belongs to another seed"))
        }
        for sentence in file.sentences where foreignSentences.contains(sentence.key) {
            issues.append(SeedIssue(seed: seedId, key: sentence.key, message: "the key belongs to another seed"))
        }
        return issues
    }

    /// Validates and imports one seed file in a single transaction.
    @discardableResult
    static func importSeed(_ file: SeedFile, origin: SeedOrigin, into database: AppDatabase, now: Date = Date()) async throws -> Report {
        let report = try await database.writer.write { db in
            let issues = try problems(of: file, in: db)
            guard issues.isEmpty else { throw ValidationFailed(issues: issues) }
            return try write(file, origin: origin, db: db, now: Int64(now.timeIntervalSince1970))
        }
        logger.info("""
            Imported \(report.seedId, privacy: .public) v\(report.version): \(report.entries) entries, \
            \(report.sentences) sentences (\(report.newSentences) new), retired \(report.retiredEntries) entries \
            and \(report.retiredSentences) sentences
            """)
        return report
    }

    private static func write(_ file: SeedFile, origin: SeedOrigin, db: Database, now: Int64) throws -> Report {
        let header = file.seed
        var report = Report(seedId: header.id, version: header.version, entries: file.entries.count, sentences: file.sentences.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func json(_ value: some Encodable) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }

        // Entries
        let upsertEntry = try db.cachedStatement(sql: """
            INSERT INTO entry (key, seed_id, level, headword, lemma, pos, gender, grp, region, parent_id, sort, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, 'active')
            ON CONFLICT(key) DO UPDATE SET
              seed_id = excluded.seed_id, level = excluded.level, headword = excluded.headword,
              lemma = excluded.lemma, pos = excluded.pos, gender = excluded.gender, grp = excluded.grp,
              region = excluded.region, parent_id = NULL, sort = excluded.sort, status = 'active'
            """)
        for (sort, entry) in file.entries.enumerated() {
            try upsertEntry.execute(arguments: [
                entry.key, header.id, header.level.rawValue, entry.headword, entry.lemma, entry.pos,
                entry.gender, entry.group, entry.region?.rawValue, sort,
            ])
        }
        var entryIds: [String: Int64] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key, id FROM entry WHERE seed_id = ?", arguments: [header.id]) {
            entryIds[row["key"]] = row["id"]
        }
        let setParent = try db.cachedStatement(sql: "UPDATE entry SET parent_id = ? WHERE id = ?")
        for entry in file.entries {
            guard let parent = entry.parent, let parentId = entryIds[parent], let id = entryIds[entry.key] else { continue }
            try setParent.execute(arguments: [parentId, id])
        }
        let entryKeys = Set(file.entries.map(\.key))
        for (key, id) in entryIds where !entryKeys.contains(key) {
            try db.execute(sql: "UPDATE entry SET status = 'retired' WHERE id = ? AND status != 'retired'", arguments: [id])
            report.retiredEntries += db.changesCount
        }

        // Sentences
        let existing = try String.fetchSet(db, sql: "SELECT key FROM sentence WHERE seed_id = ?", arguments: [header.id])
        let upsertSentence = try db.cachedStatement(sql: """
            INSERT INTO sentence (key, seed_id, level, source, de, spoken, translations, annotation, sort, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active')
            ON CONFLICT(key) DO UPDATE SET
              seed_id = excluded.seed_id, level = excluded.level, source = excluded.source, de = excluded.de,
              spoken = excluded.spoken, translations = excluded.translations, annotation = excluded.annotation,
              sort = excluded.sort, status = 'active'
            RETURNING id
            """)
        let deleteLinks = try db.cachedStatement(sql: "DELETE FROM sentence_entry WHERE sentence_id = ?")
        let insertLink = try db.cachedStatement(sql: "INSERT INTO sentence_entry (sentence_id, entry_id, tokens) VALUES (?, ?, ?)")
        for (sort, sentence) in file.sentences.enumerated() {
            if !existing.contains(sentence.key) { report.newSentences += 1 }
            let id = try Int64.fetchOne(upsertSentence, arguments: [
                sentence.key, header.id, header.level.rawValue, sentence.source.rawValue, sentence.de, sentence.spoken,
                try json(sentence.translations), try json(sentence.annotation), sort,
            ])
            guard let id else { throw DatabaseError(message: "upsert of sentence \(sentence.key) returned no id") }
            try deleteLinks.execute(arguments: [id])
            for link in sentence.entries {
                guard let entryId = entryIds[link.key] else { continue }  // validated: cannot happen
                try insertLink.execute(arguments: [id, entryId, try json(link.tokens)])
            }
        }
        let sentenceKeys = Set(file.sentences.map(\.key))
        for key in existing where !sentenceKeys.contains(key) {
            try db.execute(sql: "UPDATE sentence SET status = 'retired' WHERE key = ? AND status != 'retired'", arguments: [key])
            report.retiredSentences += db.changesCount
        }

        try SeedImport(
            seedId: header.id, title: header.title, level: header.level, version: header.version, origin: origin,
            entryCount: file.entries.count, sentenceCount: file.sentences.count, importedAt: now
        ).upsert(db)
        return report
    }
}
