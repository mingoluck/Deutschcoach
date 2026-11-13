import Foundation
import GRDB
import Testing
@testable import Deutschcoach

struct MigrationTests {
    @Test func v1CreatesAllTablesAndIndexes() async throws {
        let database = try AppDatabase.inMemory()
        let names = try await database.writer.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'index') AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'")
        }
        let expected: Set = [
            "element", "vocab_detail", "grammar_detail", "pattern_detail", "element_link", "word_form",
            "mastery", "practice_event", "batch", "sentence", "sentence_element",
            "idx_element", "idx_lemma",
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
        #expect(applied == ["v1"])
    }
}

struct SeedImportTests {
    private func makeSeed(title: String = "das Kind") throws -> SeedFile {
        let json = """
        { "elements": [
          { "key": "vocab.kind.noun", "kind": "vocab", "level": "A1", "title": "\(title)",
            "vocab": { "lemma": "Kind", "pos": "NOUN", "gender": "Neut", "plural": "Kinder" },
            "forms": [ { "form": "Kindern", "morph": "Dat|Plur" } ],
            "links": [ { "to": "gram.nom.subject", "kind": "related" } ] },
          { "key": "vocab.gehen.verb", "kind": "vocab", "level": "A1", "title": "gehen",
            "vocab": { "lemma": "gehen", "pos": "VERB",
              "verb_forms": { "praesens": { "ich": "gehe", "er": "geht", "wir": "gehen", "sie": "gehen" },
                              "partizip2": "gegangen", "aux": "sein" } } },
          { "key": "gram.nom.subject", "kind": "grammar", "level": "A1", "title": "Nominativ: Subjekt",
            "grammar": { "category": "case", "annotation_labels": ["Nom", "Subj"] } },
          { "key": "pat.es_gibt", "kind": "pattern", "level": "A1", "title": "Es gibt ...",
            "pattern": { "template": "Es gibt {NOUN:acc}.", "slots": { "NOUN": { "case": "Acc" } } } }
        ] }
        """
        return try SeedImporter.decode(Data(json.utf8))
    }

    private func elementIds(_ database: AppDatabase) async throws -> [String: Int64] {
        try await database.writer.read { db in
            var ids: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, id FROM element") {
                ids[row["key"]] = row["id"]
            }
            return ids
        }
    }

    @Test func importsElementsDetailsFormsAndLinks() async throws {
        let database = try AppDatabase.inMemory()
        let report = try await SeedImporter.importSeed(try makeSeed(), into: database)
        #expect(report.elements == 4)
        #expect(report.links == 1)

        let summary = try await database.contentSummary()
        #expect(summary.elementsByKind == [.vocab: 2, .grammar: 1, .pattern: 1])

        let (detail, forms) = try await database.writer.read { db in
            let detail = try VocabDetail.fetchOne(db, sql: "SELECT * FROM vocab_detail WHERE lemma = 'gehen'")
            let forms = try WordForm.fetchAll(db, sql: "SELECT * FROM word_form WHERE element_id = (SELECT id FROM element WHERE key = 'vocab.gehen.verb')")
            return (detail, forms)
        }
        let verbForms = try JSONDecoder().decode(VerbForms.self, from: Data(try #require(detail?.verbForms).utf8))
        #expect(verbForms.partizip2 == "gegangen")
        #expect(Set(forms.map(\.form)) == ["gehen", "gehe", "geht", "gegangen"])
        // "gehen" is both the infinitive and the wir/sie form: one row, morph labels joined.
        #expect(forms.first { $0.form == "gehen" }?.morph == "Inf,Pres.wir,Pres.sie")
    }

    @Test func reimportKeepsCountsAndIds() async throws {
        let database = try AppDatabase.inMemory()
        let seed = try makeSeed()
        try await SeedImporter.importSeed(seed, into: database)
        let summaryBefore = try await database.contentSummary()
        let idsBefore = try await elementIds(database)

        try await SeedImporter.importSeed(seed, into: database)
        #expect(try await database.contentSummary() == summaryBefore)
        #expect(try await elementIds(database) == idsBefore)
    }

    @Test func reimportPreservesUserData() async throws {
        let database = try AppDatabase.inMemory()
        try await SeedImporter.importSeed(try makeSeed(), into: database)
        try await database.writer.write { db in
            let id = try Int64.fetchOne(db, sql: "SELECT id FROM element WHERE key = 'vocab.kind.noun'")!
            try db.execute(sql: "INSERT INTO mastery (element_id, dimension, level, last_seen_at) VALUES (?, 'recall', 4, 1)", arguments: [id])
            try db.execute(sql: "INSERT INTO practice_event (ts, element_id, dimension, mode, outcome) VALUES (1, ?, 'recall', 'recall', 'pass')", arguments: [id])
            try db.execute(sql: "INSERT INTO batch (id, status, native_lang, created_at) VALUES (1, 'done', 'zh', 1)")
            try db.execute(sql: "INSERT INTO sentence (id, batch_id, position, mode, de) VALUES (1, 1, 1, 'shadow', 'Das Kind spielt.')")
            try db.execute(sql: "INSERT INTO sentence_element (sentence_id, element_id, role) VALUES (1, ?, 'target')", arguments: [id])
        }

        try await SeedImporter.importSeed(try makeSeed(), into: database)

        let counts = try await database.writer.read { db in
            try ["mastery", "practice_event", "batch", "sentence", "sentence_element"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")!
            }
        }
        #expect(counts == [1, 1, 1, 1, 1])
        let level = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT level FROM mastery")
        }
        #expect(level == 4)
    }

    @Test func reimportUpdatesChangedContent() async throws {
        let database = try AppDatabase.inMemory()
        try await SeedImporter.importSeed(try makeSeed(), into: database)
        let idsBefore = try await elementIds(database)

        try await SeedImporter.importSeed(try makeSeed(title: "das Kind (neu)"), into: database)
        let title = try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT title FROM element WHERE key = 'vocab.kind.noun'")
        }
        #expect(title == "das Kind (neu)")
        #expect(try await elementIds(database) == idsBefore)
    }

    @Test func rejectsInvalidSeeds() throws {
        var seed = try makeSeed()
        seed.elements.append(seed.elements[0])
        #expect(throws: SeedImporter.SeedError.duplicateKey("vocab.kind.noun")) {
            try SeedImporter.validate(seed)
        }

        seed = try makeSeed()
        seed.elements[0].kind = .grammar
        #expect(throws: SeedImporter.SeedError.detailMismatch(key: "vocab.kind.noun")) {
            try SeedImporter.validate(seed)
        }
    }

    @Test func rejectsUnknownLinkTargets() async throws {
        let database = try AppDatabase.inMemory()
        var seed = try makeSeed()
        seed.elements[0].links = [SeedLink(to: "does.not.exist", kind: .related)]
        await #expect(throws: SeedImporter.SeedError.unknownLinkTarget(from: "vocab.kind.noun", to: "does.not.exist")) {
            try await SeedImporter.importSeed(seed, into: database)
        }
        // The failed import is rolled back as a whole.
        #expect(try await database.contentSummary().totalElements == 0)
    }

    @Test func bundledSeedImportsTwiceIdentically() async throws {
        let database = try AppDatabase.inMemory()
        let seed = try SeedImporter.loadBundledSeed()
        let first = try await SeedImporter.importSeed(seed, into: database)
        let summary = try await database.contentSummary()
        let second = try await SeedImporter.importSeed(seed, into: database)

        #expect(first == second)
        #expect(summary.totalElements >= 30)
        #expect(try await database.contentSummary() == summary)
    }
}
