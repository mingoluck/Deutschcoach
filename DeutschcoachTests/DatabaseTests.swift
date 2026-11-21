import Foundation
import GRDB
import Testing
@testable import Deutschcoach

struct MigrationTests {
    @Test func migrationsCreateAllTablesAndIndexes() async throws {
        let database = try AppDatabase.inMemory()
        let names = try await database.writer.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'index') AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'")
        }
        let expected: Set = [
            "seed_import", "entry", "sentence", "sentence_entry",
            "progress", "practice_event", "session", "session_item",
            "idx_entry", "idx_sentence",
        ]
        #expect(names == expected)
    }

    @Test func foreignKeysAreEnabled() async throws {
        let database = try AppDatabase.inMemory()
        let enabled = try await database.writer.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        #expect(enabled == true)
    }

    @Test func migratingTwiceIsANoOp() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        _ = try AppDatabase(queue)
        let applied = try queue.read { db in try AppDatabase.migrator.appliedMigrations(db) }
        #expect(applied == ["v1", "v2", "v3", "v4"])
    }

    @Test func v3DropsTheVersion01TablesAndTheirData() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO element (key, kind, level, title) VALUES ('vocab.kind.noun', 'vocab', 'A1', 'das Kind')")
            try db.execute(sql: "INSERT INTO mastery (element_id, dimension) VALUES (1, 'recall')")
            try db.execute(sql: "INSERT INTO seed_import (seed_id, title, version, element_count, imported_at) VALUES ('old', 'Old', 1, 1, 0)")
        }
        _ = try AppDatabase(queue)
        try queue.read { db throws in
            for table in ["element", "vocab_detail", "mastery", "batch", "sentence_element", "word_form"] {
                #expect(try !db.tableExists(table))
            }
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM seed_import") == 0)
            #expect(try db.columns(in: "seed_import").map(\.name).contains("origin"))
        }
    }

    @Test func v4ReplacesDimensionsWithOneLadderRecomputedFromTheEvents() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sentence (id, key, seed_id, level, source, de, translations, annotation, sort)
                VALUES (1, 'a1.x.1', 'x', 'A1', 'goethe', 'Hallo.', '{}', '{}', 1)
                """)
            try db.execute(sql: "INSERT INTO progress (sentence_id, dimension, level, last_seen_at) VALUES (1, 'pronunciation', 3, 2), (1, 'recall', 1, 4)")
            // Two passed shadowings, a passed and a failed cloze; one event of a sentence that is gone.
            try db.execute(sql: """
                INSERT INTO practice_event (ts, sentence_id, dimension, mode, outcome) VALUES
                  (1, 1, 'pronunciation', 'shadow', 'pass'), (2, 1, 'pronunciation', 'shadow', 'pass'),
                  (3, 1, 'recall', 'cloze', 'pass'), (4, 1, 'recall', 'cloze', 'fail'),
                  (5, 999, 'recall', 'cloze', 'pass')
                """)
        }
        _ = try AppDatabase(queue)
        try queue.read { db throws in
            // 2 → 3 → 4 → 5 → 4
            #expect(try Progress.fetchAll(db) == [Progress(sentenceId: 1, level: 4, lastSeenAt: 4)])
            #expect(try PracticeEvent.fetchCount(db) == 5)
            #expect(try !db.columns(in: "practice_event").map(\.name).contains("dimension"))
            #expect(try db.columns(in: "progress").map(\.name) == ["sentence_id", "level", "last_seen_at"])
        }
    }
}

// MARK: - Fixture

enum Fixture {
    /// The debug seed doubles as the test fixture (12 sentences, one of them regional).
    static func data() throws -> Data {
        DebugSeed.data
    }

    static func seed() throws -> SeedFile {
        try SeedImporter.decode(data())
    }

    /// The fixture seed with a new version, as a file in the temporary directory.
    static func writeTemporary(_ file: SeedFile, name: String = "seed-\(UUID().uuidString)") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name).json")
        try JSONEncoder().encode(file).write(to: url)
        return url
    }
}

// MARK: - Validation (DESIGN.md §4.3)

struct SeedValidatorTests {
    private func messages(_ change: (inout SeedFile) -> Void) throws -> [String] {
        var file = try Fixture.seed()
        change(&file)
        return SeedValidator.validate(file).map(\.message)
    }

    private func sentenceIndex(_ key: String, in file: SeedFile) -> Int {
        file.sentences.firstIndex { $0.key == key }!
    }

    @Test func fixtureIsValid() throws {
        #expect(SeedValidator.validate(try Fixture.seed()).isEmpty)
    }

    @Test func formsMustReproduceTheSentence() throws {
        let found = try messages { $0.sentences[0].de = "Wir fahren um 12 Uhr los." }
        #expect(found.contains("the forms of words do not reproduce de"))
    }

    @Test func digitsNeedSpoken() throws {
        #expect(try messages { $0.sentences[0].spoken = nil }.contains("de contains digits but spoken is missing"))
        #expect(try messages { $0.sentences[0].spoken = "Wir fahren um 12 Uhr ab." }.contains("spoken contains digits"))
    }

    @Test func translationsInBothLanguages() throws {
        #expect(try messages { $0.sentences[1].translations["en"] = nil }.contains("missing en translation"))
        #expect(try messages { $0.sentences[1].translations["zh"] = "The sea air does me good." }
            .contains("the zh translation has no Chinese characters"))
        #expect(try messages { $0.sentences[1].translations["en"] = "海边的空气。" }
            .contains("the en translation contains Chinese characters"))
    }

    @Test func labelsMustBeInTheLabelSet() throws {
        let found = try messages { file in
            file.sentences[1].words[2].pos = "VRB"
            file.sentences[1].words[1].feature = "Fin"
            file.sentences[1].words[1].gender = nil
            file.sentences[1].words[4].gender = "Fem"
            file.sentences[1].spans.append(AnnotationSpan(fn: "Obj", tokens: [3]))
        }
        #expect(found.contains("token 2 \"tut\": unknown POS VRB"))
        #expect(found.contains("token 1 \"Seeluft\": needs a case, has \"Fin\""))
        #expect(found.contains("token 4 \"gut\": item 5 is only for nouns"))
        #expect(found.contains("unknown span label Obj"))
    }

    @Test func nounsNeedAGender() throws {
        let found = try messages { $0.sentences[1].words[1].gender = nil }
        #expect(found.contains("token 1 \"Seeluft\": a noun needs item 5 (gender)"))
    }

    @Test func tokenIndicesInRangeAndNoPunctuation() throws {
        let found = try messages { file in
            file.sentences[2].spans[0].tokens = [9]
            file.sentences[2].spans[1].tokens.append(4)
            file.sentences[3].entries[0].tokens = [7]
        }
        #expect(found.contains("span Subj token 9 out of range"))
        #expect(found.contains("span Pred contains punctuation"))
        #expect(found.contains("entry a1.dbg_luege token out of range"))
    }

    @Test func entryTokensCarryTheEntryLemma() throws {
        let found = try messages { $0.sentences[2].entries[0].tokens = [1] }
        #expect(found.contains("the tokens of entry a1.dbg_luegen do not have its lemma lügen"))
        #expect(SeedValidator.lemma("abfahren", matches: ["abfahren", "abfahren"]))
        #expect(SeedValidator.lemma("Auf Wiedersehen", matches: ["auf", "Wiedersehen"]))
        #expect(SeedValidator.lemma("Luft", matches: ["Seeluft"]))
        #expect(SeedValidator.lemma("Lehrer", matches: ["Lehrerin"]))
        #expect(SeedValidator.lemma("Arzt", matches: ["Ärztin"]))
        #expect(SeedValidator.lemma("Beamte", matches: ["Beamtin"]))
        #expect(!SeedValidator.lemma("gehen", matches: ["fahren"]))
    }

    @Test func entriesMustResolve() throws {
        let found = try messages { file in
            file.sentences[0].entries.append(SeedSentenceEntry(key: "a1.dbg_nirgends", tokens: [0]))
            file.entries[4].parent = "a1.dbg_nirgends"
            file.sentences[1].entries = []
        }
        #expect(found.contains("entry a1.dbg_nirgends is not in this file"))
        #expect(found.contains("parent a1.dbg_nirgends is not an entry of this file"))
        #expect(found.contains("links no entry"))
    }

    @Test func keysAreUniqueAndWellFormed() throws {
        let found = try messages { file in
            file.entries.append(file.entries[0])
            file.sentences[1].key = file.sentences[0].key
            file.sentences[2].key = "a2.dbg_luegen.1"
            file.entries[1].key = "a1.Uhr"
        }
        #expect(found.contains("duplicate entry key"))
        #expect(found.contains("duplicate sentence key"))
        #expect(found.contains("malformed sentence key"))
        #expect(found.contains("malformed entry key"))
        #expect(SeedValidator.isKey("a2.bank.2", prefix: "a2.", numberedParts: 0...1))
        #expect(SeedValidator.isKey("a2.bank.2.1", prefix: "a2.", numberedParts: 1...2))
        #expect(!SeedValidator.isKey("a2.bank", prefix: "a2.", numberedParts: 1...2))
        #expect(SeedValidator.isKey("b1.sich_lohnen", prefix: "b1.", numberedParts: 0...1))
    }

    @Test func wrongRowLengthFailsToDecode() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: Fixture.data()) as? [String: Any])
        var sentences = try #require(json["sentences"] as? [[String: Any]])
        var words = try #require(sentences[0]["words"] as? [[String]])
        words[0] = ["Wir", "wir", "PRON"]
        sentences[0]["words"] = words
        json["sentences"] = sentences
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try SeedImporter.decode(data) }
    }

    /// The seeds shipped with the app must pass validation (DESIGN.md §4.3).
    @Test func bundledSeedsAreValid() throws {
        for url in BundledSeeds.urls() {
            let file = try SeedImporter.decode(Data(contentsOf: url))
            let issues = SeedValidator.validate(file)
            #expect(issues.isEmpty, "\(url.lastPathComponent): \(issues.prefix(20).map(\.localizedDescription))")
            #expect(file.seed.id == url.deletingPathExtension().lastPathComponent)
        }
    }
}

// MARK: - Import (DESIGN.md §2.5)

struct SeedImportTests {
    private func counts(_ database: AppDatabase) async throws -> [String: Int] {
        try await database.writer.read { db in
            var result: [String: Int] = [:]
            for table in ["entry", "sentence", "sentence_entry", "seed_import"] {
                result[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
            }
            result["retired"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sentence WHERE status = 'retired'")
            return result
        }
    }

    private func ids(_ database: AppDatabase) async throws -> [String: Int64] {
        try await database.writer.read { db in
            var ids: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, id FROM sentence UNION ALL SELECT key, id FROM entry") {
                ids[row["key"]] = row["id"]
            }
            return ids
        }
    }

    @Test func importsEntriesSentencesAndLinks() async throws {
        let database = try AppDatabase.inMemory()
        let report = try await SeedImporter.importSeed(try Fixture.seed(), origin: .bundled, into: database)
        #expect(report.entries == 14 && report.sentences == 12 && report.newSentences == 12)
        #expect(try await counts(database) == ["entry": 14, "sentence": 12, "sentence_entry": 14, "seed_import": 1, "retired": 0])

        try await database.writer.read { db in
            let sentence = try #require(try Sentence.filter(Column("key") == "a1.dbg_abfahren.1").fetchOne(db))
            #expect(sentence.matchText == "Wir fahren um zwölf Uhr ab.")
            #expect(sentence.translation(for: "zh") == "我们十二点出发。")
            #expect(try sentence.decodedAnnotation().words.count == 7)
            #expect(sentence.level == .a1 && sentence.source == .goethe)

            let links = try SentenceEntry.filter(Column("sentence_id") == sentence.id).fetchAll(db)
            #expect(Set(links.map(\.decodedTokens)) == [[1, 5], [4]])

            let lie = try #require(try Entry.filter(Column("key") == "a1.dbg_luege").fetchOne(db))
            let lieVerb = try #require(try Entry.filter(Column("key") == "a1.dbg_luegen").fetchOne(db))
            #expect(lie.parentId == lieVerb.id)
            let parkieren = try #require(try Entry.filter(Column("key") == "a1.dbg_parkieren").fetchOne(db))
            #expect(parkieren.region == .ch)
            #expect(try Entry.filter(Column("key") == "a1.dbg_rot").fetchOne(db)?.grp == "Farben")

            let seed = try #require(try SeedImport.fetchOne(db, key: "debug_a1"))
            #expect(seed.version == 1 && seed.origin == .bundled && seed.entryCount == 14 && seed.sentenceCount == 12)
        }
    }

    @Test func reimportKeepsCountsAndIds() async throws {
        let database = try AppDatabase.inMemory()
        try await SeedImporter.importSeed(try Fixture.seed(), origin: .bundled, into: database)
        let before = try await ids(database)
        let report = try await SeedImporter.importSeed(try Fixture.seed(), origin: .bundled, into: database)
        #expect(report.newSentences == 0)
        #expect(try await ids(database) == before)
        #expect(try await counts(database)["sentence_entry"] == 14)
    }

    @Test func newVersionUpdatesRetiresAndKeepsUserData() async throws {
        let database = try AppDatabase.inMemory()
        try await SeedImporter.importSeed(try Fixture.seed(), origin: .bundled, into: database)
        let before = try await ids(database)
        let removedId = try #require(before["a1.dbg_luft.1"])
        try await database.writer.write { db in
            try Progress(sentenceId: removedId, level: 3, lastSeenAt: 1).insert(db)
            var event = PracticeEvent(ts: 1, sessionId: nil, sentenceId: removedId, mode: .shadow, outcome: .pass)
            try event.insert(db)
        }

        var file = try Fixture.seed()
        file.seed.version = 2
        file.sentences[0].translations["en"] = "We set off at twelve o'clock."
        file.sentences.removeAll { $0.key == "a1.dbg_luft.1" }
        file.entries.removeAll { $0.key == "a1.dbg_luft" }
        let report = try await SeedImporter.importSeed(file, origin: .bundled, into: database)
        #expect(report.retiredEntries == 1 && report.retiredSentences == 1)

        #expect(try await ids(database) == before)
        try await database.writer.read { db in
            let removed = try #require(try Sentence.fetchOne(db, key: removedId))
            #expect(removed.status == .retired)
            #expect(try Progress.fetchCount(db) == 1)
            #expect(try PracticeEvent.fetchCount(db) == 1)
            let changed = try #require(try Sentence.filter(Column("key") == "a1.dbg_abfahren.1").fetchOne(db))
            #expect(changed.translation(for: "en") == "We set off at twelve o'clock.")
            #expect(try SeedImport.fetchOne(db, key: "debug_a1")?.version == 2)
        }

        // Bringing the sentence back reactivates it under the same id.
        file = try Fixture.seed()
        file.seed.version = 3
        try await SeedImporter.importSeed(file, origin: .bundled, into: database)
        try await database.writer.read { db throws in
            #expect(try Sentence.fetchOne(db, key: removedId)?.status == .active)
        }
    }

    @Test func invalidSeedWritesNothing() async throws {
        let database = try AppDatabase.inMemory()
        var file = try Fixture.seed()
        file.sentences[0].spoken = nil
        await #expect(throws: SeedImporter.ValidationFailed.self) {
            try await SeedImporter.importSeed(file, origin: .bundled, into: database)
        }
        #expect(try await counts(database) == ["entry": 0, "sentence": 0, "sentence_entry": 0, "seed_import": 0, "retired": 0])
    }

    @Test func keysOfAnotherSeedAreRejected() async throws {
        let database = try AppDatabase.inMemory()
        try await SeedImporter.importSeed(try Fixture.seed(), origin: .bundled, into: database)
        var other = try Fixture.seed()
        other.seed.id = "other_a1"
        do {
            try await SeedImporter.importSeed(other, origin: .user, into: database)
            Issue.record("expected a validation failure")
        } catch let failure as SeedImporter.ValidationFailed {
            #expect(failure.issues.contains { $0.key == "a1.dbg_abfahren" && $0.message == "the key belongs to another seed" })
        }
    }
}

// MARK: - Bundled seeds (DESIGN.md §2.5)

struct BundledSeedsTests {
    @Test func importsOnlyNewerVersions() async throws {
        let database = try AppDatabase.inMemory()
        let v1 = try Fixture.writeTemporary(try Fixture.seed())
        defer { try? FileManager.default.removeItem(at: v1) }

        let first = await BundledSeeds.importIfNeeded([v1], into: database)
        #expect(first.imported.map(\.version) == [1] && first.failures.isEmpty)
        let again = await BundledSeeds.importIfNeeded([v1], into: database)
        #expect(again.imported.isEmpty && again.failures.isEmpty)

        var newer = try Fixture.seed()
        newer.seed.version = 2
        let v2 = try Fixture.writeTemporary(newer)
        defer { try? FileManager.default.removeItem(at: v2) }
        let updated = await BundledSeeds.importIfNeeded([v2], into: database)
        #expect(updated.imported.map(\.version) == [2])
    }

    @Test func brokenSeedIsSkippedAndReported() async throws {
        let database = try AppDatabase.inMemory()
        var broken = try Fixture.seed()
        broken.seed.id = "broken_a1"
        broken.entries = broken.entries.map { entry in
            var entry = entry
            entry.key = entry.key.replacingOccurrences(of: "a1.", with: "a1.x")
            return entry
        }
        broken.sentences = []
        broken.entries[0].pos = "XYZ"
        let bad = try Fixture.writeTemporary(broken, name: "broken_a1")
        let good = try Fixture.writeTemporary(try Fixture.seed())
        let garbage = FileManager.default.temporaryDirectory.appending(path: "garbage-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: garbage)
        defer { for url in [bad, good, garbage] { try? FileManager.default.removeItem(at: url) } }

        let outcome = await BundledSeeds.importIfNeeded([bad, garbage, good], into: database)
        #expect(outcome.imported.map(\.seedId) == ["debug_a1"])
        #expect(outcome.failures.count == 2)
        #expect(outcome.failures[0].seedId == "broken_a1")
        #expect(outcome.failures[0].message.contains("unknown POS XYZ"))
    }
}

// MARK: - Clearing data (DESIGN.md §2.6)

struct ClearDataTests {
    private func seededDatabase() async throws -> AppDatabase {
        let database = try AppDatabase.inMemory()
        try await SeedImporter.importSeed(try Fixture.seed(), origin: .bundled, into: database)
        try await database.writer.write { db in
            let sentenceId = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM sentence LIMIT 1"))
            var session = Session(level: .a1, status: .active, createdAt: 1)
            try session.insert(db)
            try SessionItem(sessionId: session.id!, position: 1, sentenceId: sentenceId, mode: .shadow, status: .done).insert(db)
            try Progress(sentenceId: sentenceId, level: 2, lastSeenAt: 1).insert(db)
            var event = PracticeEvent(ts: 1, sessionId: session.id, sentenceId: sentenceId, mode: .shadow, outcome: .pass)
            try event.insert(db)
        }
        return database
    }

    @Test func clearingRecordsKeepsContent() async throws {
        let database = try await seededDatabase()
        #expect(try await database.libraryStats().practiceEvents == 1)
        try await database.clearPracticeRecords()
        let stats = try await database.libraryStats()
        #expect(stats.practiceEvents == 0 && stats.sessions == 0)
        #expect(stats.sentences[.a1] == 12 && stats.entries[.a1] == 14)
        #expect(stats.seeds.map(\.seedId) == ["debug_a1"])
    }

    @Test func resetDeletesEverythingAndContentCanBeImportedAgain() async throws {
        let database = try await seededDatabase()
        try await database.resetAllData()
        let empty = try await database.libraryStats()
        #expect(empty.totalSentences == 0 && empty.seeds.isEmpty && empty.practiceEvents == 0)

        let v1 = try Fixture.writeTemporary(try Fixture.seed())
        defer { try? FileManager.default.removeItem(at: v1) }
        let outcome = await BundledSeeds.importIfNeeded([v1], into: database)
        #expect(outcome.imported.count == 1)
        #expect(try await database.libraryStats().sentences[.a1] == 12)
    }
}
