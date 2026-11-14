import Foundation
import GRDB
import Testing
@testable import Deutschcoach

// MARK: - Support

/// A deterministic generator (SplitMix64) for selection tests.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Stores one template batch ("Ich gebe den Kindern einen Apfel.") with the given modes and
/// returns its batch id.
@discardableResult
func storeTemplateBatch(_ database: AppDatabase, ids: TemplateIds, modes: [SentenceMode]) async throws -> Int64 {
    let model = FakeLanguageModel { request, _ in
        GenerationResponse(sentences: request.sentences.map { ids.sentence(position: $0.position) }, malformed: [], usage: TokenUsage())
    }
    var request = ids.request(positions: 1...modes.count)
    for index in modes.indices { request.sentences[index].mode = modes[index] }
    return try await BatchGenerator(database: database, model: model).generate(request).batchId
}

func firstItem(_ database: AppDatabase, batch: Int64) async throws -> PracticeItem {
    try #require(try await PracticeStore(database: database).nextItem(inBatch: batch))
}

// MARK: - Mastery rules

struct MasteryRulesTests {
    @Test func threePassesLevelUpAndStartOver() {
        #expect(MasteryRules.level(after: []) == 1)
        #expect(MasteryRules.level(after: [.pass, .pass]) == 1)
        #expect(MasteryRules.level(after: [.pass, .pass, .pass]) == 2)
        #expect(MasteryRules.level(after: [.pass, .pass, .pass, .pass, .pass]) == 2)
        #expect(MasteryRules.level(after: Array(repeating: .pass, count: 6)) == 3)
    }

    @Test func failDropsALevelAndResetsTheStreak() {
        #expect(MasteryRules.level(after: [.fail]) == 1)
        #expect(MasteryRules.level(after: [.pass, .pass, .pass, .fail]) == 1)
        #expect(MasteryRules.level(after: [.pass, .pass, .fail, .pass, .pass]) == 1)
    }

    @Test func notAttemptedNeitherCountsNorBreaksTheStreak() {
        #expect(MasteryRules.level(after: [.pass, .notAttempted, .pass, .notAttempted, .pass]) == 2)
    }

    @Test func levelsStayWithinOneToFive() {
        #expect(MasteryRules.level(after: Array(repeating: .pass, count: 30)) == 5)
    }
}

// MARK: - Element selection

struct ElementPickerTests {
    @Test func modeTable() {
        #expect(ElementPicker.mode(pronunciation: 1, recall: 1) == .shadow)
        #expect(ElementPicker.mode(pronunciation: 2, recall: 4) == .shadow)
        #expect(ElementPicker.mode(pronunciation: 3, recall: 2) == .cloze)
        #expect(ElementPicker.mode(pronunciation: 3, recall: 3) == .recall)
        #expect(ElementPicker.mode(pronunciation: 5, recall: 5) == .recall)
    }

    @Test func freshDatabaseGivesTenShadowSentences() async throws {
        let database = try await makeSeededDatabase()
        let request = try await database.writer.read { db in try ElementPicker(nativeLang: "zh").makeRequest(from: db) }
        #expect(request.sentences.map(\.position) == Array(1...10))
        #expect(request.userLevel == .a1 && request.nativeLang == "zh")
        for sentence in request.sentences {
            let kinds = sentence.targets.map(\.kind)
            #expect(kinds.first == .vocab)  // the primary target
            #expect(kinds.filter { $0 == .grammar }.count == 1)
            #expect((1...3).contains(kinds.filter { $0 == .vocab }.count))
            #expect(kinds.filter { $0 == .pattern }.count <= 1)
            #expect(Set(sentence.targets.map(\.elementId)).count == sentence.targets.count)
            #expect(sentence.mode == .shadow)
        }
        // 13 grammar points: no repeats within the batch even with prerequisites relaxed.
        let grammar = request.sentences.flatMap(\.targets).filter { $0.kind == .grammar }.map(\.elementId)
        #expect(Set(grammar).count == 10)
    }

    @Test func modeFollowsThePrimaryVocabularyMastery() async throws {
        let database = try await makeSeededDatabase()
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO mastery (element_id, dimension, level)
                SELECT id, 'pronunciation', 3 FROM element WHERE kind = 'vocab'
                """)
        }
        var request = try await database.writer.read { db in try ElementPicker().makeRequest(from: db) }
        #expect(request.sentences.allSatisfy { $0.mode == .cloze })

        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO mastery (element_id, dimension, level)
                SELECT id, 'recall', 3 FROM element WHERE kind = 'vocab'
                """)
        }
        request = try await database.writer.read { db in try ElementPicker().makeRequest(from: db) }
        #expect(request.sentences.allSatisfy { $0.mode == .recall })
    }

    private func candidate(_ id: Int64, _ kind: ElementKind, pron: Int = 1, recall: Int = 1, lastSeen: Int64? = nil, prerequisites: [Int64] = []) -> ElementPicker.Candidate {
        ElementPicker.Candidate(id: id, kind: kind, title: "e\(id)", pronunciation: pron, recall: recall, lastSeen: lastSeen, prerequisites: prerequisites)
    }

    @Test func unmetPrerequisitesAreSkippedWhileOthersRemain() {
        // Grammar 10 requires grammar 11 (recall 1: not met); grammar 12 requires 13 (recall 2: met).
        let candidates = (1...30).map { candidate(Int64($0), .vocab) } + [
            candidate(10_000, .grammar, prerequisites: [11_000]),
            candidate(11_000, .grammar),
            candidate(12_000, .grammar, prerequisites: [13_000]),
            candidate(13_000, .grammar, recall: 2),
        ]
        var rng = SeededGenerator(state: 1)
        let request = ElementPicker(count: 3, nativeLang: "zh").makeRequest(candidates: candidates, using: &rng)
        let grammar = request.sentences.flatMap(\.targets).filter { $0.kind == .grammar }.map(\.elementId)
        #expect(Set(grammar) == [11_000, 12_000, 13_000])
    }

    @Test func prerequisitesAreRelaxedWhenCandidatesRunOut() {
        let candidates = (1...30).map { candidate(Int64($0), .vocab) } + [
            candidate(10_000, .grammar, prerequisites: [11_000]),
            candidate(11_000, .grammar),
        ]
        var rng = SeededGenerator(state: 2)
        let request = ElementPicker(count: 3, nativeLang: "zh").makeRequest(candidates: candidates, using: &rng)
        let grammar = request.sentences.map { $0.targets.filter { $0.kind == .grammar }.map(\.elementId) }
        #expect(grammar.allSatisfy { $0.count == 1 })
        #expect(Set(grammar.flatMap { $0 }) == [10_000, 11_000])  // both used, then repeats
    }

    @Test func weakAndStaleElementsWeighMore() {
        let now = Date(timeIntervalSince1970: 100 * 86_400).timeIntervalSince1970
        var rng = SeededGenerator(state: 3)
        func weight(_ c: ElementPicker.Candidate) -> Double {
            (0..<200).map { _ in ElementPicker.weight(of: c, now: now, using: &rng) }.reduce(0, +) / 200
        }
        let fresh = weight(candidate(1, .vocab))
        let strong = weight(candidate(2, .vocab, pron: 5, recall: 5, lastSeen: Int64(now)))
        let strongButStale = weight(candidate(3, .vocab, pron: 5, recall: 5, lastSeen: Int64(now) - 30 * 86_400))
        #expect(fresh > strongButStale && strongButStale > strong)
        // Vocabulary uses the weaker dimension.
        #expect(weight(candidate(4, .vocab, pron: 5, recall: 1, lastSeen: Int64(now))) > strong * 10)
    }
}

// MARK: - Cloze blanks

struct ClozeBlanksTests {
    @Test func oneBlankPerTargetAtMostThree() async throws {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let sentence = ids.sentence(position: 1)
        let words = sentence.words.map { AnnotationToken(form: $0[0], lemma: $0[1], pos: $0[2], feature: $0[3]) }
        for seed in 0..<20 {
            var rng = SeededGenerator(state: UInt64(seed))
            let blanks = ClozeBlanks.choose(targets: sentence.targets, words: words, using: &rng)
            // geben → 1, Kind → 3, Dativ → 2 or 3 (3 already taken by Kind, so 2).
            #expect(blanks == [1, 2, 3])
        }
        var rng = SeededGenerator(state: 0)
        let many = (0..<5).map { TargetTokens(elementId: Int64($0), tokens: [$0]) }
        #expect(ClozeBlanks.choose(targets: many, words: words, using: &rng).count == 3)
        #expect(ClozeBlanks.choose(targets: [TargetTokens(elementId: 1, tokens: [6])], words: words, using: &rng).isEmpty)
    }

    @Test func storedOnlyForClozeSentences() async throws {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let batch = try await storeTemplateBatch(database, ids: ids, modes: [.shadow, .cloze, .recall])
        let blanks = try await database.writer.read { db in
            try String?.fetchAll(db, sql: "SELECT blanks FROM sentence WHERE batch_id = ? ORDER BY position", arguments: [batch])
        }
        #expect(blanks == [nil, "[1,2,3]", nil])
    }
}

// MARK: - Scoring

struct ScorerTests {
    private func item(_ mode: SentenceMode) async throws -> (TemplateIds, PracticeItem, AppDatabase) {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let batch = try await storeTemplateBatch(database, ids: ids, modes: [mode])
        return (ids, try await firstItem(database, batch: batch), database)
    }

    private func outcomes(_ events: [EventDraft]) -> [Int64: PracticeOutcome] {
        Dictionary(uniqueKeysWithValues: events.map { ($0.elementId, $0.outcome) })
    }

    @Test func shadowScoresVocabularyIncludingIncidentalButNotGrammar() async throws {
        let (ids, item, database) = try await item(.shadow)
        let apfel = try await elementId("vocab.apfel.noun", in: database)

        let perfect = Scorer.scoreShadow(item, heard: "ich gebe den Kindern einen Apfel")
        #expect(outcomes(perfect.events) == [ids.geben: .pass, ids.kind: .pass, apfel: .pass])
        #expect(perfect.events.allSatisfy { $0.dimension == .pronunciation })

        let misread = Scorer.scoreShadow(item, heard: "Ich gebe den Kinder einen Apfel")
        #expect(outcomes(misread.events) == [ids.geben: .pass, ids.kind: .fail, apfel: .pass])
        #expect(misread.alignment?.allMatched == false)

        let silent = Scorer.scoreShadow(item, heard: " ")
        #expect(silent.events.allSatisfy { $0.outcome == .notAttempted && $0.reason == .noSpeech })
        let skipped = Scorer.scoreShadow(item, heard: nil, skipped: true)
        #expect(skipped.events.allSatisfy { $0.outcome == .notAttempted && $0.reason == .skipped })
    }

    @Test func localPassNeedsAllTargets() async throws {
        let (ids, item, _) = try await item(.cloze)
        guard case .pass(let events) = Scorer.scoreLocally(item, heard: "Ich gebe den Kindern einen Apfel.") else {
            Issue.record("expected pass"); return
        }
        #expect(outcomes(events) == [ids.geben: .pass, ids.kind: .pass, ids.dativ: .pass])
        #expect(events.allSatisfy { $0.dimension == .recall })

        // Vocabulary is lenient: another form of "geben" and of "Kind" passes …
        if case .pass = Scorer.scoreLocally(item, heard: "Ich gab den Kindern einen Apfel") {} else { Issue.record("gab should pass") }
        // … grammar is strict: "dem Kind" is not "den Kindern".
        #expect(Scorer.scoreLocally(item, heard: "Ich gebe dem Kind einen Apfel") == .needsJudge)
        #expect(Scorer.scoreLocally(item, heard: "Ich schenke den Kindern einen Apfel") == .needsJudge)
    }

    @Test func noSpeechOrSkipIsNotAttempted() async throws {
        let (_, item, _) = try await item(.recall)
        guard case .notAttempted(let events) = Scorer.scoreLocally(item, heard: "") else { Issue.record("expected notAttempted"); return }
        #expect(events.count == 3 && events.allSatisfy { $0.reason == .noSpeech })
        guard case .notAttempted(let skipped) = Scorer.scoreLocally(item, heard: "Ich", skipped: true) else { Issue.record("expected notAttempted"); return }
        #expect(skipped.allSatisfy { $0.reason == .skipped })
    }

    @Test func judgeVerdictTable() async throws {
        let (ids, item, _) = try await item(.recall)
        let targets = item.targets

        let unclear = Scorer.events(from: JudgeVerdict(valid: true, confidence: .low, targetsUsed: [ids.geben]), targets: targets)
        #expect(unclear.allSatisfy { $0.outcome == .notAttempted && $0.reason == .unclear })

        let invalid = Scorer.events(from: JudgeVerdict(valid: false, confidence: .high, targetsUsed: []), targets: targets)
        #expect(invalid.allSatisfy { $0.outcome == .fail })

        let paraphrase = Scorer.events(from: JudgeVerdict(valid: true, confidence: .high, targetsUsed: [ids.geben, ids.dativ]), targets: targets)
        #expect(outcomes(paraphrase) == [ids.geben: .pass, ids.kind: .notAttempted, ids.dativ: .pass])
        #expect(paraphrase.first { $0.elementId == ids.kind }?.reason == .paraphrase)

        let request = Scorer.judgeRequest(for: item, heard: "Ich gebe dem Kind einen Apfel", nativeLang: "zh")
        #expect(request.translation == "我给孩子们一个苹果。")
        #expect(request.reference == "Ich gebe den Kindern einen Apfel.")
        #expect(request.targets.map(\.elementId) == targets.map(\.id))
    }

    @Test func separableVerbNeedsItsPrefix() async throws {
        let database = try await makeSeededDatabase()
        let id = try await elementId("vocab.aufstehen.verb", in: database)
        let item = try await database.writer.write { db -> PracticeItem in
            let empty = SentenceAnnotation(words: [], spans: [])
            var batch = Batch(status: .active, nativeLang: "zh", createdAt: 0)
            try batch.insert(db)
            var sentence = Sentence(batchId: batch.id!, position: 1, mode: .recall, status: .pending, de: "",
                                    translations: "{}", annotation: String(decoding: try JSONEncoder().encode(empty), as: UTF8.self),
                                    flagged: false)
            try sentence.insert(db)
            try SentenceElement(sentenceId: sentence.id!, elementId: id, role: .target, tokens: "[]").insert(db)
            return try PracticeItem.load(sentence, from: db)
        }
        let element = try #require(item.targets.first)
        #expect(element.separablePrefix == "auf")
        #expect(Scorer.vocabularyHeard(element, in: ["ich", "stehe", "um", "sieben", "auf"]))
        #expect(Scorer.vocabularyHeard(element, in: ["ich", "bin", "aufgestanden"]))
        #expect(Scorer.vocabularyHeard(element, in: ["ich", "will", "aufstehen"]))
        #expect(!Scorer.vocabularyHeard(element, in: ["ich", "stehe", "hier"]))
    }
}

// MARK: - Writing answers, batches, pruning

struct PracticeStoreTests {
    @Test func recordWritesEventsMasteryAndStatusTogether() async throws {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let batch = try await storeTemplateBatch(database, ids: ids, modes: [.cloze, .cloze, .cloze, .cloze])
        let clock = TestClock()
        let store = PracticeStore(database: database, now: { clock.now })
        #expect(try await store.prepareOnLaunch() == batch)

        let verdict = JudgeVerdict(valid: true, confidence: .high, targetsUsed: [ids.geben])
        for round in 1...3 {
            let item = try await firstItem(database, batch: batch)
            clock.advance(60)
            let done = try await store.record(
                [EventDraft(elementId: ids.geben, dimension: .recall, outcome: .pass),
                 EventDraft(elementId: ids.kind, dimension: .recall, outcome: .notAttempted, reason: .paraphrase)],
                for: item, status: .done, heard: "Ich gebe dem Kind einen Apfel", engine: "fake", judge: verdict
            )
            #expect(!done)
            #expect(try await store.progress(ofBatch: batch) == (round, 4))
        }

        let (geben, kind, event) = try await database.writer.read { db in
            (try Mastery.fetchOne(db, key: ["element_id": ids.geben, "dimension": "recall"]),
             try Mastery.fetchOne(db, key: ["element_id": ids.kind, "dimension": "recall"]),
             try PracticeEvent.fetchOne(db, sql: "SELECT * FROM practice_event WHERE element_id = ? ORDER BY id DESC", arguments: [ids.kind]))
        }
        #expect(geben?.level == 2)                      // three passes
        #expect(geben?.lastSeenAt == Int64(clock.now.timeIntervalSince1970))
        #expect(kind?.level == 1)                       // not_attempted only
        #expect(event?.mode == .cloze && event?.outcome == .notAttempted)
        let detail = try JSONDecoder().decode(PracticeEventDetail.self, from: Data(try #require(event?.detail).utf8))
        #expect(detail == PracticeEventDetail(heard: "Ich gebe dem Kind einen Apfel", engine: "fake", reason: .paraphrase, judge: verdict))

        // The last sentence finishes the batch.
        let last = try await firstItem(database, batch: batch)
        #expect(try await store.record([], for: last, status: .skipped, heard: nil, engine: nil))
        let status = try await database.writer.read { db in try Batch.fetchOne(db, key: batch)?.status }
        #expect(status == .done)
    }

    @Test func masteryCanBeRecomputedFromEvents() async throws {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let batch = try await storeTemplateBatch(database, ids: ids, modes: Array(repeating: .shadow, count: 4))
        let store = PracticeStore(database: database)
        for _ in 1...3 {
            let item = try await firstItem(database, batch: batch)
            try await store.record([EventDraft(elementId: ids.kind, dimension: .pronunciation, outcome: .pass)], for: item, status: .done, heard: "x", engine: "fake")
        }
        try await database.writer.write { db in try db.execute(sql: "UPDATE mastery SET level = 5") }
        try await store.recomputeAllMastery()
        let level = try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT level FROM mastery WHERE element_id = ?", arguments: [ids.kind]) }
        #expect(level == 2)
    }

    @Test func launchDeletesGeneratingAndPromotesReady() async throws {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let ready = try await storeTemplateBatch(database, ids: ids, modes: [.shadow])
        try await database.writer.write { db in
            var leftover = Batch(status: .generating, nativeLang: "zh", createdAt: 0)
            try leftover.insert(db)
        }
        let store = PracticeStore(database: database)
        #expect(try await store.prepareOnLaunch() == ready)
        let statuses = try await database.writer.read { db in try Batch.fetchAll(db).map(\.status) }
        #expect(statuses == [.active])
        #expect(try await store.prepareOnLaunch() == ready)  // resumes the active batch
        #expect(try await !store.hasReadyBatch())
    }

    @Test func pruningKeepsTheTenMostRecentDoneBatchesAndAllEvents() async throws {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let clock = TestClock()
        let store = PracticeStore(database: database, now: { clock.now })
        var batches: [Int64] = []
        for _ in 1...12 {
            let batch = try await storeTemplateBatch(database, ids: ids, modes: [.shadow])
            batches.append(batch)
            #expect(try await store.activeOrPromote() == batch)
            clock.advance(60)
            let item = try await firstItem(database, batch: batch)
            #expect(try await store.record([EventDraft(elementId: ids.kind, dimension: .pronunciation, outcome: .pass)],
                                           for: item, status: .done, heard: "x", engine: "fake"))
        }
        let (kept, sentences, events) = try await database.writer.read { db in
            (try Int64.fetchAll(db, sql: "SELECT id FROM batch ORDER BY id"),
             try Sentence.fetchCount(db),
             try PracticeEvent.fetchCount(db))
        }
        #expect(kept == Array(batches.suffix(10)))
        #expect(sentences == 10)
        #expect(events == 12)
    }
}

/// A clock tests can move forward.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

// MARK: - Judge request and response

struct JudgeLLMTests {
    private let request = JudgeRequest(
        mode: .recall,
        translation: "我给孩子们一个苹果。",
        reference: "Ich gebe den Kindern einen Apfel.",
        targets: [.init(elementId: 101, title: "geben")],
        answer: "Ich gebe dem Kind einen Apfel"
    )

    @Test func requestForcesTheToolWithoutThinking() throws {
        let model = ClaudeLanguageModel(client: ClaudeClient(apiKey: { "k" }))
        let body = try JSONSerialization.jsonObject(with: model.judgeRequestBody(for: request)) as! [String: Any]
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
        let choice = body["tool_choice"] as? [String: Any]
        #expect(choice?["type"] as? String == "tool" && choice?["name"] as? String == "submit_verdict")
        #expect(body["temperature"] == nil)
        let tool = (body["tools"] as? [[String: Any]])?.first
        #expect(tool?["strict"] as? Bool == true)
        let message = ((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(message?.contains("\"answer\":\"Ich gebe dem Kind einen Apfel\"") == true)
        #expect(message?.contains("\"element_id\":101") == true)
    }

    @Test func requestWithThinkingUsesAutoToolChoice() throws {
        var model = ClaudeLanguageModel(client: ClaudeClient(apiKey: { "k" }))
        model.judgeThinking = true
        let body = try JSONSerialization.jsonObject(with: model.judgeRequestBody(for: request)) as! [String: Any]
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((body["tool_choice"] as? [String: Any])?["type"] as? String == "auto")
    }

    @Test func parsesTheVerdict() throws {
        let response: [String: Any] = [
            "stop_reason": "tool_use",
            "content": [["type": "tool_use", "id": "t", "name": "submit_verdict",
                         "input": ["valid": true, "confidence": "high", "targets_used": [101]]]],
            "usage": ["input_tokens": 1, "output_tokens": 1],
        ]
        let verdict = try ClaudeLanguageModel.parseVerdict(JSONSerialization.data(withJSONObject: response))
        #expect(verdict == JudgeVerdict(valid: true, confidence: .high, targetsUsed: [101]))

        let noCall: [String: Any] = ["stop_reason": "end_turn", "content": [["type": "text", "text": "ok"]]]
        #expect(throws: LLMError.noToolCall("submit_verdict")) {
            try ClaudeLanguageModel.parseVerdict(JSONSerialization.data(withJSONObject: noCall))
        }
    }
}
