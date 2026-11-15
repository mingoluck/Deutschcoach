import Foundation
import GRDB
import Testing
@testable import Deutschcoach

// MARK: - Seed import (DESIGN.md §2.5)

struct MultiFileImportTests {
    private func source(_ name: String, id: String, _ elements: String) throws -> SeedImporter.Source {
        let json = """
        { "seed": { "id": "\(id)", "title": "\(id) title", "version": 2 }, "elements": [ \(elements) ] }
        """
        return SeedImporter.Source(name: name, file: try SeedImporter.decode(Data(json.utf8)))
    }

    private var core: SeedImporter.Source {
        get throws {
            try source("core.json", id: "core", """
                { "key": "gram.nom.subject", "kind": "grammar", "level": "A1", "title": "Nominativ: Subjekt",
                  "grammar": { "category": "case" } }
                """)
        }
    }

    private var vocab: SeedImporter.Source {
        get throws {
            try source("vocab.json", id: "vocab", """
                { "key": "vocab.kind.noun", "kind": "vocab", "level": "A1", "title": "das Kind",
                  "vocab": { "lemma": "Kind", "pos": "NOUN", "gender": "Neut", "plural": "Kinder" },
                  "links": [ { "to": "gram.nom.subject", "kind": "related" } ] },
                { "key": "vocab.und.cconj", "kind": "vocab", "level": "A1", "title": "und", "targetable": false,
                  "vocab": { "lemma": "und", "pos": "CCONJ" } }
                """)
        }
    }

    @Test func importsSeveralFilesWithCrossFileLinks() async throws {
        let database = try AppDatabase.inMemory()
        let report = try await SeedImporter.importSeeds([try vocab, try core], into: database, now: Date(timeIntervalSince1970: 1_000))
        #expect(report == SeedImporter.Report(files: 2, elements: 3, wordForms: 3, links: 1))  // Kind, Kinder, und

        let (seeds, targetable) = try await database.writer.read { db in
            (try SeedImport.order(Column("seed_id")).fetchAll(db),
             try Bool.fetchOne(db, sql: "SELECT targetable FROM element WHERE key = 'vocab.und.cconj'"))
        }
        #expect(seeds == [
            SeedImport(seedId: "core", title: "core title", version: 2, elementCount: 1, importedAt: 1_000),
            SeedImport(seedId: "vocab", title: "vocab title", version: 2, elementCount: 2, importedAt: 1_000),
        ])
        #expect(targetable == false)
    }

    @Test func linksMayPointToElementsAlreadyInTheDatabase() async throws {
        let database = try AppDatabase.inMemory()
        try await SeedImporter.importSeeds([try core], into: database)
        let preview = try await SeedImporter.preview([try vocab], database: database)
        #expect(preview.issues.isEmpty)
        try await SeedImporter.importSeeds([try vocab], into: database)
        #expect(try await database.contentSummary().links == 1)
    }

    @Test func previewCountsNewAndUpdatedElementsWithoutWriting() async throws {
        let database = try AppDatabase.inMemory()
        var preview = try await SeedImporter.preview([try core, try vocab], database: database)
        #expect(preview.canImport)
        #expect(preview.files.map(\.new) == [1, 2])
        #expect(preview.files.map(\.updated) == [0, 0])
        #expect(try await database.contentSummary().totalElements == 0)

        try await SeedImporter.importSeeds(preview.sources, into: database)
        preview = try await SeedImporter.preview([try core, try vocab], database: database)
        #expect(preview.files.map(\.new) == [0, 0])
        #expect(preview.files.map(\.updated) == [1, 2])
    }

    @Test func previewReportsEveryProblem() async throws {
        let database = try AppDatabase.inMemory()
        let duplicate = try source("again.json", id: "vocab", """
            { "key": "vocab.kind.noun", "kind": "vocab", "level": "A1", "title": "das Kind",
              "vocab": { "lemma": "Kind", "pos": "NOUN" } }
            """)
        // Without core.json, the link to gram.nom.subject is unknown.
        let preview = try await SeedImporter.preview([try vocab, duplicate], database: database)
        #expect(!preview.canImport)
        #expect(Set(preview.issues) == [
            .duplicateSeedId("vocab"),
            .duplicateKey("vocab.kind.noun"),
            .unknownLinkTarget(from: "vocab.kind.noun", to: "gram.nom.subject"),
        ])
    }

    @Test func importWithProblemsWritesNothing() async throws {
        let database = try AppDatabase.inMemory()
        await #expect(throws: SeedImporter.SeedError.unknownLinkTarget(from: "vocab.kind.noun", to: "gram.nom.subject")) {
            try await SeedImporter.importSeeds([try vocab], into: database)
        }
        #expect(try await database.contentSummary().totalElements == 0)
    }

    @Test func unreadableFilesAreReportedNotThrown() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appending(path: "good.json")
        let bad = directory.appending(path: "bad.json")
        try Data(#"{ "seed": { "id": "g", "title": "G", "version": 1 }, "elements": [] }"#.utf8).write(to: good)
        try Data(#"{ "elements": [ { "key": 1 } ] }"#.utf8).write(to: bad)

        let loaded = SeedImporter.load(urls: [good, bad])
        #expect(loaded.sources.map(\.name) == ["good.json"])
        guard case .unreadable(let file, _) = try #require(loaded.issues.first) else {
            Issue.record("expected an unreadable-file issue")
            return
        }
        #expect(file == "bad.json")
    }
}

// MARK: - Clearing data (DESIGN.md §2.6)

struct ClearingDataTests {
    private func addPractice(_ database: AppDatabase) async throws {
        try await database.writer.write { db in
            let id = try Int64.fetchOne(db, sql: "SELECT id FROM element WHERE key = 'vocab.kind.noun'")!
            try db.execute(sql: "INSERT INTO mastery (element_id, dimension, level) VALUES (?, 'recall', 3)", arguments: [id])
            try db.execute(sql: "INSERT INTO practice_event (ts, element_id, dimension, mode, outcome) VALUES (1, ?, 'recall', 'recall', 'pass')", arguments: [id])
            try db.execute(sql: "INSERT INTO batch (id, status, native_lang, created_at) VALUES (1, 'done', 'zh', 1)")
            try db.execute(sql: "INSERT INTO sentence (id, batch_id, position, mode, de) VALUES (1, 1, 1, 'shadow', 'Das Kind spielt.')")
            try db.execute(sql: "INSERT INTO sentence_element (sentence_id, element_id, role) VALUES (1, ?, 'target')", arguments: [id])
        }
    }

    private func counts(_ database: AppDatabase) async throws -> [String: Int] {
        try await database.writer.read { db in
            var counts: [String: Int] = [:]
            for table in ["element", "word_form", "element_link", "vocab_detail", "seed_import",
                          "mastery", "practice_event", "batch", "sentence", "sentence_element"] {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
            }
            return counts
        }
    }

    @Test func clearingPracticeRecordsKeepsTheContent() async throws {
        let database = try await makeSeededDatabase()
        try await addPractice(database)
        let before = try await counts(database)

        try await database.clearPracticeRecords()
        let after = try await counts(database)
        for table in ["mastery", "practice_event", "batch", "sentence", "sentence_element"] {
            #expect(after[table] == 0, "\(table)")
        }
        for table in ["element", "word_form", "element_link", "vocab_detail", "seed_import"] {
            #expect(after[table] == before[table], "\(table)")
            #expect(after[table]! > 0, "\(table)")
        }
    }

    @Test func resetDeletesEverythingButKeepsTheSchema() async throws {
        let database = try await makeSeededDatabase()
        try await addPractice(database)

        try await database.resetAllData()
        #expect(try await counts(database).values.allSatisfy { $0 == 0 })
        // Importing works again on the same connection.
        try await SeedImporter.importSeed(try loadFixtureSeed(), into: database)
        #expect(try await database.contentSummary().totalElements > 0)
    }

    @Test func backupsAreCopiesAndOnlyTheNewestFiveStay() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(DatabasePool(path: directory.appending(path: "db.sqlite").path(percentEncoded: false)))
        try await SeedImporter.importSeed(try loadFixtureSeed(), into: database)

        var urls: [URL] = []
        for day in 1...7 {
            urls.append(try #require(try database.backup(now: Date(timeIntervalSince1970: TimeInterval(day * 86_400)))))
        }
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Backups").path(percentEncoded: false)).sorted()
        #expect(kept == urls.suffix(5).map(\.lastPathComponent))

        let copy = try DatabaseQueue(path: urls.last!.path(percentEncoded: false))
        let elements = try await copy.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM element") }
        #expect(elements == (try await database.contentSummary().totalElements))
    }

    @Test func inMemoryDatabasesAreNotBackedUp() throws {
        #expect(try AppDatabase.inMemory().backup() == nil)
    }
}

// MARK: - Selection (DESIGN.md §3.2)

struct LibrarySelectionTests {
    @Test func nonTargetableElementsAreNeverTargets() async throws {
        let database = try await makeSeededDatabase()
        let kind = try await elementId("vocab.kind.noun", in: database)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE element SET targetable = 0 WHERE id = ?", arguments: [kind])
        }
        let candidates = try await database.writer.read { db in try ElementPicker.loadCandidates(upTo: .a1, from: db) }
        #expect(!candidates.contains { $0.id == kind })
        #expect(!candidates.isEmpty)
    }

    @Test func practicableContentNeedsVocabularyAndGrammar() async throws {
        let database = try AppDatabase.inMemory()
        func check() async throws -> Bool {
            try await database.writer.read { db in try ElementPicker.hasPracticableContent(upTo: .a1, in: db) }
        }
        #expect(try await check() == false)

        try await SeedImporter.importSeed(try loadFixtureSeed(), into: database)
        #expect(try await check() == true)

        try await database.writer.write { db in
            try db.execute(sql: "UPDATE element SET status = 'retired' WHERE kind = 'grammar'")
        }
        #expect(try await check() == false)
    }

    @Test func aBatchIntroducesAtMostFiveNewWordsInFrequencyOrder() {
        // 30 practiced words, 30 new ones ranked 1…30, and grammar.
        let practiced = (1...30).map {
            ElementPicker.Candidate(id: Int64($0), kind: .vocab, title: "p\($0)", key: "p\($0)", pronunciation: 2, recall: 2)
        }
        let new = (1...30).map {
            ElementPicker.Candidate(id: Int64(100 + $0), kind: .vocab, title: "n\($0)", key: "n\($0)", freqRank: $0, isNew: true)
        }
        let grammar = (1...10).map { ElementPicker.Candidate(id: Int64(1_000 + $0), kind: .grammar, title: "g\($0)") }

        for seed in 0..<20 {
            var rng = SeededGenerator(state: UInt64(seed))
            let request = ElementPicker(nativeLang: "zh", userLevel: .a1)
                .makeRequest(candidates: (new + practiced + grammar).shuffled(using: &rng), using: &rng)
            let picked = Set(request.sentences.flatMap(\.targets).map(\.elementId)).filter { $0 > 100 && $0 < 1_000 }
            #expect(picked.count <= ElementPicker.newVocabWindow)
            #expect(picked.allSatisfy { $0 <= 100 + Int64(ElementPicker.newVocabWindow) })
        }
    }

    @Test func theWindowWidensWhenNothingElseIsLeft() {
        // Only new words: a batch needs more than five, so the window widens in frequency order.
        let new = (1...40).map {
            ElementPicker.Candidate(id: Int64($0), kind: .vocab, title: "n\($0)", key: "n\($0)", freqRank: $0, isNew: true)
        }
        let grammar = [ElementPicker.Candidate(id: 1_000, kind: .grammar, title: "g")]
        var rng = SeededGenerator(state: 7)
        let request = ElementPicker(nativeLang: "zh", userLevel: .a1).makeRequest(candidates: new + grammar, using: &rng)
        let picked = Set(request.sentences.flatMap(\.targets).filter { $0.kind == .vocab }.map(\.elementId))
        #expect(picked.count > ElementPicker.newVocabWindow)
        // The window widens only when every admitted word is used, so the picks are exactly the
        // most frequent words.
        #expect(picked == Set((1...Int64(picked.count)).map { $0 }))
    }
}

// MARK: - Engine (DESIGN.md §3.1)

@MainActor
struct LibraryEngineTests {
    private func makeEngine(_ database: AppDatabase, model: FakeLanguageModel, network: FakeNetwork = FakeNetwork(), level: CEFRLevel = .a1) -> PracticeEngine {
        PracticeEngine(database: database, model: model, recognizer: SilentRecognizer(), speaker: SilentSpeaker(),
                       network: network, nativeLang: "zh", userLevel: level)
    }

    private func batchStatuses(_ database: AppDatabase) async throws -> [BatchStatus] {
        try await database.writer.read { db in try Batch.order(Column("id")).fetchAll(db).map(\.status) }
    }

    @Test func emptyLibraryPromptsForImportWithoutCallingTheLLM() async throws {
        let database = try AppDatabase.inMemory()
        let model = makeGeneratingModel(database)
        let network = FakeNetwork()
        network.isOnline = false
        let engine = makeEngine(database, model: model, network: network)

        await engine.start()
        #expect(engine.status == .emptyLibrary)
        // The empty library comes before the LLM-unavailable block.
        await engine.networkChanged(online: false)
        #expect(engine.status == .emptyLibrary)
        #expect(model.requests.isEmpty)

        network.isOnline = true
        try await SeedImporter.importSeed(try loadFixtureSeed(), into: database)
        await engine.libraryChanged()
        #expect(engine.status == .waitingForBatch)
        await engine.waitForGeneration()
        #expect(engine.status == .practicing)
    }

    @Test func aLevelWithoutContentIsAnEmptyLibrary() async throws {
        let database = try await makeSeededDatabase()
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE element SET level = 'B1' WHERE kind = 'grammar'")
        }
        let model = makeGeneratingModel(database)
        let engine = makeEngine(database, model: model)
        await engine.start()
        #expect(engine.status == .emptyLibrary)

        await engine.changeLevel(to: .b1)
        #expect(engine.status == .waitingForBatch)
        await engine.waitForGeneration()
        #expect(engine.status == .practicing)
        #expect(model.requests.last?.userLevel == .b1)
    }

    @Test func resetReturnsToTheEmptyLibrary() async throws {
        let database = try await makeSeededDatabase()
        let model = makeGeneratingModel(database)
        let engine = makeEngine(database, model: model)
        await engine.start()
        await engine.waitForGeneration()
        await engine.waitForGeneration()
        #expect(engine.status == .practicing)

        engine.prepareForDataReset()
        try await database.resetAllData()
        await engine.dataWasReset()
        #expect(engine.status == .emptyLibrary)
        #expect(engine.item == nil)
    }

    @Test func clearingRecordsStartsAFreshBatch() async throws {
        let database = try await makeSeededDatabase()
        let model = makeGeneratingModel(database)
        let engine = makeEngine(database, model: model)
        await engine.start()
        await engine.waitForGeneration()
        await engine.waitForGeneration()
        #expect(try await batchStatuses(database) == [.active, .ready])

        engine.prepareForDataReset()
        try await database.clearPracticeRecords()
        await engine.dataWasReset()
        #expect(engine.status == .waitingForBatch)
        await engine.waitForGeneration()
        #expect(engine.status == .practicing)
    }

    @Test func changingTheLevelReplacesOnlyTheReadyBatch() async throws {
        let database = try await makeSeededDatabase()
        let model = makeGeneratingModel(database)
        let engine = makeEngine(database, model: model)
        await engine.start()
        await engine.waitForGeneration()
        await engine.waitForGeneration()
        let before = try await database.writer.read { db in try Batch.order(Column("id")).fetchAll(db) }
        #expect(before.map(\.status) == [.active, .ready])
        let item = engine.item
        let requestsBefore = model.requests.count

        await engine.changeLevel(to: .a2)
        await engine.waitForGeneration()
        let after = try await database.writer.read { db in try Batch.order(Column("id")).fetchAll(db) }
        #expect(after.map(\.status) == [.active, .ready])
        #expect(after[0].id == before[0].id)
        #expect(model.requests.count == requestsBefore + 1)  // the ready batch was regenerated
        #expect(engine.item == item)
        #expect(model.requests.last?.userLevel == .a2)
    }
}
