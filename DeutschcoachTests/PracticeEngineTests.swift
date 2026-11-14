import Foundation
import GRDB
import Synchronization
import Testing
@testable import Deutschcoach

/// A recognizer that is never asked to transcribe: tests answer through `submit(heard:skipped:)`.
final class SilentRecognizer: SpeechRecognizer {
    let engineName = "fake-recognizer"
    func availability() async -> RecognizerAvailability { .ready }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func transcribe(_ audio: AsyncStream<AudioChunk>, onVolatile: @escaping @Sendable (String) -> Void) async throws -> Transcript {
        Transcript(text: "", words: [], engine: engineName)
    }
}

/// A network monitor tests switch by hand; the engine is told through `networkChanged`.
final class FakeNetwork: NetworkMonitor {
    var isOnline = true
    func start(_ handler: @escaping @MainActor (Bool) -> Void) {}
}

final class SilentSpeaker: SentenceSpeaker {
    private(set) var spoken: [String] = []
    func speak(_ text: String) async { spoken.append(text) }
    func stop() {}
}

/// Generates a valid sentence for any request: one token per target. Vocabulary tokens use the
/// lemma so that validation (§4.3 rule 5) accepts them.
func makeGeneratingModel(_ database: AppDatabase, judge: @escaping @Sendable (JudgeRequest) throws -> JudgeVerdict = { _ in JudgeVerdict(valid: true, confidence: .high, targetsUsed: []) }) -> FakeLanguageModel {
    FakeLanguageModel(judge: judge) { request, _ in try generatedResponse(for: request, database: database) }
}

func generatedResponse(for request: GenerationRequest, database: AppDatabase) throws -> GenerationResponse {
        let sentences = try request.sentences.map { sentenceRequest in
            var words: [[String]] = []
            var targets: [TargetTokens] = []
            for target in sentenceRequest.targets {
                let row: [String]
                if target.kind == .vocab {
                    let (lemma, pos) = try database.writer.read { db in
                        let row = try Row.fetchOne(db, sql: "SELECT lemma, pos FROM vocab_detail WHERE element_id = ?", arguments: [target.elementId])!
                        return (row["lemma"] as String, row["pos"] as String)
                    }
                    row = [lemma, lemma, pos, ""]
                } else {
                    row = ["und", "und", "CCONJ", ""]
                }
                targets.append(TargetTokens(elementId: target.elementId, tokens: [words.count]))
                words.append(row)
            }
            words.append([".", "", "PUNCT", ""])
            let de = words.dropLast().map { $0[0] }.joined(separator: " ") + "."
            return GeneratedSentence(position: sentenceRequest.position, de: de, translation: "译文 \(sentenceRequest.position)",
                                     words: words, spans: [], targets: targets)
        }
        return GenerationResponse(sentences: sentences, malformed: [], usage: TokenUsage())
}

@MainActor
struct PracticeEngineTests {
    private func makeEngine(_ database: AppDatabase, model: FakeLanguageModel, speaker: SilentSpeaker = SilentSpeaker(), network: FakeNetwork = FakeNetwork()) -> PracticeEngine {
        PracticeEngine(database: database, model: model, recognizer: SilentRecognizer(), speaker: speaker, network: network, nativeLang: "zh")
    }

    private func batchStatuses(_ database: AppDatabase) async throws -> [BatchStatus] {
        try await database.writer.read { db in try Batch.order(Column("id")).fetchAll(db).map(\.status) }
    }

    @Test func practicesTwoFullBatches() async throws {
        let database = try await makeSeededDatabase()
        let model = makeGeneratingModel(database)
        let speaker = SilentSpeaker()
        let engine = makeEngine(database, model: model, speaker: speaker)

        await engine.start()
        #expect(engine.status == .waitingForBatch)
        await engine.waitForGeneration()          // first batch, generated on the spot
        #expect(engine.status == .practicing)
        await engine.waitForGeneration()          // pre-generated second batch
        #expect(try await batchStatuses(database) == [.active, .ready])

        for batch in 1...2 {
            for position in 1...10 {
                let item = try #require(engine.item)
                #expect(item.mode == .shadow)
                #expect(engine.progress == (position - 1, 10))
                await engine.submit(heard: item.sentence.de, skipped: false)
                #expect(engine.step == .result)
                #expect(engine.outcome?.events.allSatisfy { $0.outcome == .pass } == true)
                await engine.next()
            }
            await engine.waitForGeneration()      // the batch after the one just activated
            #expect(model.requests.count == batch + 2)
        }

        #expect(try await batchStatuses(database) == [.done, .done, .active, .ready])
        let (events, mastery) = try await database.writer.read { db in
            (try PracticeEvent.fetchCount(db), try Mastery.fetchCount(db))
        }
        #expect(events > 20)
        #expect(mastery > 0)
        // Shadowing reads the sentence before and after each answer.
        #expect(speaker.spoken.count >= 40)
    }

    @Test func clozeAnswerGoesToTheJudge() async throws {
        let database = try await makeSeededDatabase()
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO mastery (element_id, dimension, level) SELECT id, 'pronunciation', 3 FROM element WHERE kind = 'vocab'")
        }
        let model = makeGeneratingModel(database) { request in
            JudgeVerdict(valid: false, confidence: .high, targetsUsed: [])
        }
        let engine = makeEngine(database, model: model)
        await engine.start()
        await engine.waitForGeneration()
        let item = try #require(engine.item)
        #expect(item.mode == .cloze && !item.blanks.isEmpty)

        await engine.submit(heard: "Das ist etwas ganz anderes", skipped: false)
        #expect(model.judgeRequests.count == 1)
        #expect(model.judgeRequests.first?.answer == "Das ist etwas ganz anderes")
        #expect(engine.outcome?.verdict?.valid == false)
        #expect(engine.outcome?.events.count == item.targets.count)
        #expect(engine.outcome?.events.allSatisfy { $0.outcome == .fail && $0.dimension == .recall } == true)

        // A correct answer passes locally, without the judge.
        await engine.next()
        let second = try #require(engine.item)
        await engine.submit(heard: second.sentence.de, skipped: false)
        #expect(model.judgeRequests.count == 1)
        #expect(engine.outcome?.events.allSatisfy { $0.outcome == .pass } == true)
    }

    @Test func judgeFailureBlocksAndRetryResendsTheSameAnswer() async throws {
        let database = try await makeSeededDatabase()
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO mastery (element_id, dimension, level) SELECT id, 'pronunciation', 3 FROM element WHERE kind = 'vocab'")
        }
        let failing = FailSwitch()
        let model = makeGeneratingModel(database) { request in
            if failing.isOn { throw LLMError.network("offline") }
            return JudgeVerdict(valid: true, confidence: .high, targetsUsed: [])
        }
        let engine = makeEngine(database, model: model)
        await engine.start()
        await engine.waitForGeneration()
        await engine.waitForGeneration()
        let item = try #require(engine.item)

        failing.isOn = true
        await engine.submit(heard: "Etwas anderes", skipped: false)
        guard case .unavailable = engine.status else { Issue.record("expected unavailable, got \(engine.status)"); return }
        let written = try await database.writer.read { db in try PracticeEvent.fetchCount(db) }
        #expect(written == 0)  // the attempt is not written

        failing.isOn = false
        await engine.retryAfterFailure()
        #expect(engine.status == .practicing && engine.step == .result)
        #expect(model.judgeRequests.map(\.answer) == ["Etwas anderes", "Etwas anderes"])
        #expect(engine.item == item)
        #expect(engine.outcome?.events.allSatisfy { $0.reason == .paraphrase } == true)
    }

    @Test func generationFailureBlocksUntilRetry() async throws {
        let database = try await makeSeededDatabase()
        let failing = FailSwitch()
        failing.isOn = true
        let model = FakeLanguageModel { request, _ in
            if failing.isOn { throw LLMError.invalidAPIKey }
            return try generatedResponse(for: request, database: database)
        }
        let engine = makeEngine(database, model: model)
        await engine.start()
        await engine.waitForGeneration()
        #expect(engine.status == .unavailable(LLMError.invalidAPIKey.localizedDescription))
        #expect(try await batchStatuses(database).isEmpty)  // the failed batch is deleted

        failing.isOn = false
        await engine.retryAfterFailure()
        #expect(engine.status == .waitingForBatch)
        await engine.waitForGeneration()
        #expect(engine.status == .practicing)
    }

    // MARK: - M6: network, API key, language

    private func batches(_ database: AppDatabase) async throws -> [(BatchStatus, String)] {
        try await database.writer.read { db in try Batch.order(Column("id")).fetchAll(db).map { ($0.status, $0.nativeLang) } }
    }

    @Test func offlineAtLaunchBlocksUntilTheNetworkReturns() async throws {
        let database = try await makeSeededDatabase()
        let model = makeGeneratingModel(database)
        let network = FakeNetwork()
        network.isOnline = false
        let engine = makeEngine(database, model: model, network: network)

        await engine.start()
        #expect(engine.status == .unavailable(LLMError.offline.localizedDescription))
        #expect(model.requests.isEmpty)  // nothing is sent while offline

        await engine.retryAfterFailure()  // Retry while still offline: stays blocked
        #expect(engine.isBlocked && model.requests.isEmpty)

        network.isOnline = true
        await engine.networkChanged(online: true)
        await engine.waitForGeneration()
        #expect(engine.status == .practicing)
    }

    @Test func losingTheNetworkBlocksAtOnceAndReturningResumes() async throws {
        let database = try await makeSeededDatabase()
        let model = makeGeneratingModel(database)
        let network = FakeNetwork()
        let engine = makeEngine(database, model: model, network: network)
        await engine.start()
        await engine.waitForGeneration()
        await engine.waitForGeneration()
        let item = try #require(engine.item)
        #expect(model.requests.count == 2)

        network.isOnline = false
        await engine.networkChanged(online: false)
        #expect(engine.isBlocked)

        network.isOnline = true
        await engine.networkChanged(online: true)
        #expect(engine.status == .practicing && engine.item == item && engine.step == .prompt)
        #expect(model.requests.count == 2)  // a ready batch exists: nothing to regenerate
    }

    @Test func failedGenerationWhileOfflineIsRetriedWhenOnline() async throws {
        let database = try await makeSeededDatabase()
        let failing = FailSwitch()
        failing.isOn = true
        let model = FakeLanguageModel { request, _ in
            if failing.isOn { throw LLMError.network("The Internet connection appears to be offline.") }
            return try generatedResponse(for: request, database: database)
        }
        let network = FakeNetwork()
        let engine = makeEngine(database, model: model, network: network)
        await engine.start()
        await engine.waitForGeneration()
        #expect(engine.isBlocked)

        // The monitor notices the outage after the call failed; the pending generation is kept.
        network.isOnline = false
        await engine.networkChanged(online: false)
        failing.isOn = false
        network.isOnline = true
        await engine.networkChanged(online: true)
        await engine.waitForGeneration()
        #expect(engine.status == .practicing)
    }

    @Test func savingAKeyRetriesOnce() async throws {
        let database = try await makeSeededDatabase()
        let failing = FailSwitch()
        failing.isOn = true
        let model = FakeLanguageModel { request, _ in
            if failing.isOn { throw LLMError.invalidAPIKey }
            return try generatedResponse(for: request, database: database)
        }
        let engine = makeEngine(database, model: model)
        await engine.start()
        await engine.waitForGeneration()
        #expect(engine.status == .unavailable(LLMError.invalidAPIKey.localizedDescription))

        failing.isOn = false
        await engine.apiKeyChanged()
        await engine.waitForGeneration()
        #expect(engine.status == .practicing)
    }

    @Test func aRejectedOrDeletedKeyBlocksAtOnceAndAGoodKeyResumes() async throws {
        let database = try await makeSeededDatabase()
        let model = makeGeneratingModel(database)
        let engine = makeEngine(database, model: model)
        await engine.start()
        await engine.waitForGeneration()
        await engine.waitForGeneration()  // a ready batch exists: no LLM call is pending
        let item = try #require(engine.item)
        let calls = model.requests.count

        model.accessError.withLock { $0 = .invalidAPIKey }  // a wrong key was saved
        await engine.apiKeyChanged()
        #expect(engine.status == .unavailable(LLMError.invalidAPIKey.localizedDescription))

        model.accessError.withLock { $0 = .missingAPIKey }  // then deleted
        await engine.apiKeyChanged()
        #expect(engine.status == .unavailable(LLMError.missingAPIKey.localizedDescription))

        await engine.retryAfterFailure()  // Retry re-checks the key
        #expect(engine.isBlocked)

        model.accessError.withLock { $0 = nil }  // a good key
        await engine.apiKeyChanged()
        #expect(engine.status == .practicing && engine.item == item)
        #expect(model.requests.count == calls)  // checking the key never calls the model
    }

    @Test func aRejectedKeyAtLaunchBlocks() async throws {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        try await storeTemplateBatch(database, ids: ids, modes: [.shadow])
        try await storeTemplateBatch(database, ids: ids, modes: [.shadow])  // active + ready: no generation
        let model = makeGeneratingModel(database)
        model.accessError.withLock { $0 = .invalidAPIKey }
        let engine = makeEngine(database, model: model)
        await engine.start()
        #expect(engine.status == .unavailable(LLMError.invalidAPIKey.localizedDescription))
        #expect(model.requests.isEmpty)
    }

    @Test func changingTheLanguageDiscardsCurrentBatchesAndRegenerates() async throws {
        let database = try await makeSeededDatabase()
        let model = makeGeneratingModel(database)
        let engine = makeEngine(database, model: model)
        await engine.start()
        await engine.waitForGeneration()
        await engine.waitForGeneration()
        let item = try #require(engine.item)
        await engine.submit(heard: item.sentence.de, skipped: false)
        let events = try await database.writer.read { db in try PracticeEvent.fetchCount(db) }
        #expect(try await batches(database).map(\.0) == [.active, .ready])

        await engine.changeLanguage(to: "en")
        #expect(engine.status == .waitingForBatch && engine.item == nil)
        await engine.waitForGeneration()
        await engine.waitForGeneration()
        #expect(engine.status == .practicing && engine.nativeLang == "en")
        let current = try await batches(database)
        #expect(current.map(\.0) == [.active, .ready])
        #expect(current.allSatisfy { $0.1 == "en" })
        #expect(model.requests.suffix(2).allSatisfy { $0.nativeLang == "en" })
        #expect(try await database.writer.read { db in try PracticeEvent.fetchCount(db) } == events)  // events kept
    }

    @Test func aGenerationStartedBeforeALanguageChangeIsDiscarded() async throws {
        let database = try await makeSeededDatabase()
        let gate = Gate()
        let model = FakeLanguageModel { request, call in
            if call == 1 { gate.wait() }  // the first (zh) generation finishes late
            return try generatedResponse(for: request, database: database)
        }
        let engine = makeEngine(database, model: model)
        await engine.start()
        await engine.changeLanguage(to: "en")
        gate.open()
        await engine.waitForGeneration()
        await engine.waitForGeneration()
        try await Task.sleep(for: .milliseconds(200))  // let the stale generation clean up
        let current = try await batches(database)
        #expect(current.allSatisfy { $0.1 == "en" })
        #expect(engine.status == .practicing && engine.nativeLang == "en")
    }
}

/// Blocks a fake model call until opened.
final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open() { semaphore.signal() }
}

final class FailSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}
