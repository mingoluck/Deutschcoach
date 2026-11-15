import Foundation
import GRDB
import Testing
@testable import Deutschcoach

struct SentenceValidatorTests {
    private func setUp() async throws -> (TemplateIds, SentenceValidator, SentenceRequest) {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let lexicon = try await database.writer.read { db in
            try VocabLexicon.load(elementIds: [ids.geben, ids.kind], from: db)
        }
        let request = ids.request(positions: 1...1).sentences[0]
        return (ids, SentenceValidator(lexicon: lexicon), request)
    }

    private func reason(_ result: Result<ValidatedSentence, ValidationFailure>) -> String? {
        if case .failure(let failure) = result { return failure.reason }
        return nil
    }

    @Test func acceptsAValidSentence() async throws {
        let (ids, validator, request) = try await setUp()
        let result = validator.validate(ids.sentence(position: 1), for: request)
        let validated = try result.get()
        #expect(validated.annotation.words.count == 7)
        #expect(validated.annotation.words[3].gender == "Neut|Plur")
        #expect(validated.targets.count == 3)
    }

    @Test func rejectsWrongPosition() async throws {
        let (ids, validator, request) = try await setUp()
        #expect(reason(validator.validate(ids.sentence(position: 2), for: request))?.contains("position") == true)
    }

    @Test func rejectsEmptyTranslation() async throws {
        let (ids, validator, request) = try await setUp()
        var sentence = ids.sentence(position: 1)
        sentence.translation = "  "
        #expect(reason(validator.validate(sentence, for: request)) == "empty translation")
    }

    @Test func rejectsRowsOfWrongLength() async throws {
        let (ids, validator, request) = try await setUp()
        var sentence = ids.sentence(position: 1)
        sentence.words[2] = ["den", "der", "DET"]
        #expect(reason(validator.validate(sentence, for: request)) == "row 2 has 3 items")
    }

    @Test func rejectsFormsThatDoNotReproduceTheSentence() async throws {
        let (ids, validator, request) = try await setUp()
        var sentence = ids.sentence(position: 1)
        sentence.words[5][0] = "Birne"
        #expect(reason(validator.validate(sentence, for: request))?.contains("do not reproduce") == true)
    }

    @Test func ignoresWhitespaceDifferences() async throws {
        let (ids, validator, request) = try await setUp()
        var sentence = ids.sentence(position: 1)
        sentence.de = "Ich gebe den  Kindern einen Apfel ."
        #expect(throws: Never.self) { try validator.validate(sentence, for: request).get() }
    }

    @Test func rejectsTooManyWords() async throws {
        let (ids, validator, request) = try await setUp()
        var sentence = ids.sentence(position: 1)
        let extra = Array(repeating: ["sehr", "sehr", "ADV", ""], count: 20)
        sentence.words.insert(contentsOf: extra, at: 6)
        sentence.de = sentence.words.map { $0[0] }.joined(separator: " ")
        #expect(reason(validator.validate(sentence, for: request))?.contains("26 words") == true)
    }

    @Test func rejectsOutOfRangeTokens() async throws {
        let (ids, validator, request) = try await setUp()
        var sentence = ids.sentence(position: 1)
        sentence.spans.append(AnnotationSpan(fn: "AdvT", tokens: [9]))
        #expect(reason(validator.validate(sentence, for: request))?.contains("span AdvT") == true)

        sentence = ids.sentence(position: 1)
        sentence.targets[0].tokens = []
        #expect(reason(validator.validate(sentence, for: request))?.contains("invalid tokens") == true)
    }

    @Test func rejectsMissingTarget() async throws {
        let (ids, validator, request) = try await setUp()
        var sentence = ids.sentence(position: 1)
        sentence.targets.removeAll { $0.elementId == ids.dativ }
        #expect(reason(validator.validate(sentence, for: request))?.contains("missing") == true)
    }

    @Test func rejectsVocabularyTargetAtTheWrongWord() async throws {
        let (ids, validator, request) = try await setUp()
        var sentence = ids.sentence(position: 1)
        sentence.targets[0].tokens = [5]  // "geben" located at "Apfel"
        #expect(reason(validator.validate(sentence, for: request))?.contains("not a form of geben") == true)
    }

    @Test func acceptsVocabularyTargetByKnownForm() async throws {
        let (ids, validator, request) = try await setUp()
        var sentence = ids.sentence(position: 1)
        sentence.words[1][1] = "gebe"  // wrong lemma, but "gebe" is a known form of geben
        #expect(throws: Never.self) { try validator.validate(sentence, for: request).get() }
    }

    @Test func acceptsUnknownLabels() async throws {
        let (ids, validator, request) = try await setUp()
        var sentence = ids.sentence(position: 1)
        sentence.spans.append(AnnotationSpan(fn: "Vocative", tokens: [0]))
        sentence.words[0][2] = "X"
        #expect(throws: Never.self) { try validator.validate(sentence, for: request).get() }
    }
}

struct BatchGeneratorTests {
    private func counts(_ database: AppDatabase) async throws -> (batches: Int, sentences: Int, links: Int) {
        try await database.writer.read { db in
            (try Batch.fetchCount(db), try Sentence.fetchCount(db), try SentenceElement.fetchCount(db))
        }
    }

    @Test func storesAFullBatch() async throws {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let model = FakeLanguageModel { request, _ in
            GenerationResponse(sentences: request.sentences.map { ids.sentence(position: $0.position) }, malformed: [], usage: TokenUsage(input: 10, output: 20))
        }
        let report = try await BatchGenerator(database: database, model: model).generate(ids.request())

        #expect(report.storedPositions == Array(1...10))
        #expect(report.failures.isEmpty)
        #expect(report.rounds == 1)
        #expect(report.usage == TokenUsage(input: 10, output: 20))

        let (batch, sentence, links) = try await database.writer.read { db in
            (try Batch.fetchOne(db, key: report.batchId)!,
             try Sentence.fetchOne(db, sql: "SELECT * FROM sentence WHERE batch_id = ? AND position = 1", arguments: [report.batchId])!,
             try Row.fetchAll(db, sql: "SELECT element_id, role, tokens FROM sentence_element WHERE sentence_id = (SELECT id FROM sentence WHERE batch_id = ? AND position = 1)", arguments: [report.batchId])
                .map { (row: Row) -> (Int64, String, String) in (row["element_id"], row["role"], row["tokens"]) })
        }
        #expect(batch.status == .ready)
        #expect(batch.model == "fake-model")
        #expect(batch.nativeLang == "zh")
        #expect(sentence.mode == .shadow && sentence.status == .pending)
        #expect(sentence.translation(for: "zh") == "我给孩子们一个苹果。")
        #expect(try sentence.decodedAnnotation()?.words.count == 7)
        #expect(sentence.blanks == nil)

        let byElement = Dictionary(uniqueKeysWithValues: links.map { ($0.0, ($0.1, $0.2)) })
        #expect(byElement[ids.geben]?.0 == "target")
        #expect(byElement[ids.geben]?.1 == "[1]")
        #expect(byElement[ids.dativ]?.1 == "[2,3]")
        // "Apfel" is in the seed but not a target: stored as incidental. "Kind" stays a target only.
        let apfel = try await elementId("vocab.apfel.noun", in: database)
        #expect(byElement[apfel]?.0 == "incidental")
        #expect(byElement[apfel]?.1 == "[5]")
        #expect(byElement.count == 4)
    }

    @Test func refillsOnlyTheFailedPositions() async throws {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let model = FakeLanguageModel { request, call in
            var sentences = request.sentences.map { ids.sentence(position: $0.position) }
            if call == 1 {
                sentences[1].words[0] = ["Ich"]                     // position 2: invalid row
                sentences.removeAll { $0.position == 5 }             // position 5: not returned
            }
            return GenerationResponse(sentences: sentences, malformed: [], usage: TokenUsage(input: 1, output: 1))
        }
        let report = try await BatchGenerator(database: database, model: model).generate(ids.request())

        #expect(model.requests.map { $0.sentences.map(\.position) } == [Array(1...10), [2, 5]])
        #expect(report.rounds == 2)
        #expect(report.storedPositions == Array(1...10))
        #expect(report.usage == TokenUsage(input: 2, output: 2))
    }

    @Test func acceptsFewerSentencesAfterTwoRefills() async throws {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let model = FakeLanguageModel { request, _ in
            let sentences = request.sentences.map { ids.sentence(position: $0.position) }.filter { $0.position != 3 }
            return GenerationResponse(sentences: sentences, malformed: [MalformedSentence(position: 3, reason: "could not decode")], usage: TokenUsage())
        }
        let report = try await BatchGenerator(database: database, model: model).generate(ids.request())

        #expect(model.requests.count == 3)  // first round + two refills
        #expect(report.storedPositions == [1, 2, 4, 5, 6, 7, 8, 9, 10])
        #expect(report.failures == [ValidationFailure(position: 3, reason: "could not decode")])
        #expect(try await counts(database).sentences == 9)
    }

    @Test func modelErrorDeletesTheBatch() async throws {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let model = FakeLanguageModel { _, _ in throw LLMError.overloaded }
        await #expect(throws: LLMError.overloaded) {
            try await BatchGenerator(database: database, model: model).generate(ids.request())
        }
        #expect(try await counts(database) == (0, 0, 0))
    }

    @Test func errorInARefillRoundDeletesTheBatch() async throws {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let model = FakeLanguageModel { request, call in
            if call == 2 { throw LLMError.network("offline") }
            let sentences = request.sentences.map { ids.sentence(position: $0.position) }.filter { $0.position != 1 }
            return GenerationResponse(sentences: sentences, malformed: [], usage: TokenUsage())
        }
        await #expect(throws: LLMError.network("offline")) {
            try await BatchGenerator(database: database, model: model).generate(ids.request())
        }
        #expect(try await counts(database) == (0, 0, 0))
    }

    @Test func noValidSentenceDeletesTheBatch() async throws {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let model = FakeLanguageModel { _, _ in GenerationResponse(sentences: [], malformed: [], usage: TokenUsage()) }
        await #expect(throws: BatchGenerator.GenerationError.self) {
            try await BatchGenerator(database: database, model: model).generate(ids.request(positions: 1...2))
        }
        #expect(try await counts(database) == (0, 0, 0))
    }
}

struct TranslationLanguageTests {
    @Test func translationMustBeInTheNativeLanguage() {
        #expect(SentenceValidator.isWritten("我给孩子们一个苹果。", in: "zh"))
        #expect(!SentenceValidator.isWritten("He said he had to go.", in: "zh"))
        #expect(SentenceValidator.isWritten("He said he had to go.", in: "en"))
        #expect(!SentenceValidator.isWritten("他说他得走了。", in: "en"))
    }

    @Test func wrongLanguageIsRejected() async throws {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let lexicon = try await database.writer.read { db in
            try VocabLexicon.load(elementIds: [ids.geben, ids.kind], from: db)
        }
        var sentence = ids.sentence(position: 1)
        sentence.translation = "I give the children an apple."
        let request = ids.request(positions: 1...1).sentences[0]
        let result = SentenceValidator(lexicon: lexicon, nativeLang: "zh").validate(sentence, for: request)
        guard case .failure(let failure) = result else {
            Issue.record("an English translation was accepted for zh")
            return
        }
        #expect(failure.reason.contains("not written in zh"))
        #expect(throws: Never.self) { try SentenceValidator(lexicon: lexicon, nativeLang: "en").validate(sentence, for: request).get() }
    }
}
