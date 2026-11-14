import Foundation
import GRDB
import Testing
@testable import Deutschcoach

struct HistoryTests {
    /// Two done template batches: in the first, sentence 1 passed, 2 failed, 3 skipped, 4 no speech.
    private func makeHistory() async throws -> (AppDatabase, TemplateIds, [Int64]) {
        let database = try await makeSeededDatabase()
        let ids = try await TemplateIds(database)
        let store = PracticeStore(database: database)
        var batches: [Int64] = []
        for _ in 1...2 {
            let batch = try await storeTemplateBatch(database, ids: ids, modes: [.shadow, .shadow, .recall, .recall])
            batches.append(batch)
            _ = try await store.activeOrPromote()
            let outcomes: [([EventDraft], SentenceStatus)] = [
                ([EventDraft(elementId: ids.kind, dimension: .pronunciation, outcome: .pass)], .done),
                ([EventDraft(elementId: ids.kind, dimension: .pronunciation, outcome: .pass),
                  EventDraft(elementId: ids.geben, dimension: .pronunciation, outcome: .fail)], .done),
                ([EventDraft(elementId: ids.kind, dimension: .recall, outcome: .notAttempted, reason: .skipped)], .skipped),
                ([EventDraft(elementId: ids.kind, dimension: .recall, outcome: .notAttempted, reason: .noSpeech)], .done),
            ]
            for (events, status) in outcomes {
                let item = try await firstItem(database, batch: batch)
                try await store.record(events, for: item, status: status, heard: "x", engine: "fake")
            }
        }
        return (database, ids, batches)
    }

    @Test func loadsDoneBatchesWithResults() async throws {
        let (database, _, batches) = try await makeHistory()
        // An unfinished batch is not history.
        let ids = try await TemplateIds(database)
        try await storeTemplateBatch(database, ids: ids, modes: [.shadow])

        let history = try await HistoryStore(database: database).load(language: "zh")
        #expect(Set(history.map(\.id)) == Set(batches))
        let first = try #require(history.first { $0.id == batches[0] })
        #expect(first.sentences.map(\.result) == [.passed, .mistakes, .skipped, .notScored])
        #expect(first.sentences.map(\.mode) == [.shadow, .shadow, .recall, .recall])
        #expect(first.sentences.allSatisfy { $0.translation == "我给孩子们一个苹果。" && $0.annotation != nil })
        #expect(!first.missingTranslations)
    }

    @Test func translatesMissingLanguageOnDemandAndKeepsTheOld() async throws {
        let (database, _, _) = try await makeHistory()
        let store = HistoryStore(database: database)
        let model = FakeLanguageModel { _, _ in GenerationResponse(sentences: [], malformed: [], usage: TokenUsage()) }

        let english = try await store.load(language: "en")
        let batch = try #require(english.first)
        #expect(batch.missingTranslations)

        try await store.translate(batch, into: "en", model: model)
        #expect(model.translationRequests.count == 1)
        #expect(model.translationRequests.first?.sentences.map(\.mode) == [.shadow, .shadow, .recall, .recall])

        let reloaded = try await store.load(language: "en")
        let translated = try #require(reloaded.first { $0.id == batch.id })
        #expect(translated.sentences.allSatisfy { $0.translation == "en: Ich gebe den Kindern einen Apfel." })
        #expect(reloaded.first { $0.id != batch.id }?.missingTranslations == true)  // only on demand

        let chinese = try await store.load(language: "zh")
        #expect(chinese.allSatisfy { !$0.missingTranslations })

        // Nothing missing: no call.
        try await store.translate(translated, into: "en", model: model)
        #expect(model.translationRequests.count == 1)
    }
}

struct TranslationLLMTests {
    @Test func requestForcesTheToolWithoutThinking() throws {
        let model = ClaudeLanguageModel(client: ClaudeClient(apiKey: { "k" }))
        let request = TranslationRequest(nativeLang: "en", sentences: [.init(id: 7, mode: .recall, de: "Ich gebe den Kindern einen Apfel.")])
        let body = try JSONSerialization.jsonObject(with: model.translationRequestBody(for: request)) as! [String: Any]
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect((body["tool_choice"] as? [String: Any])?["name"] as? String == "submit_translations")
        #expect((body["tools"] as? [[String: Any]])?.first?["strict"] as? Bool == true)
        let text = ((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(text?.contains("\"native_lang\":\"en\"") == true)
        #expect(text?.contains("\"mode\":\"recall\"") == true)
    }

    @Test func parsesTranslations() throws {
        let response: [String: Any] = [
            "stop_reason": "tool_use",
            "content": [["type": "tool_use", "id": "t", "name": "submit_translations",
                         "input": ["translations": [["id": 7, "translation": " I give the children an apple. "],
                                                    ["id": 8, "translation": "  "]]]]],
        ]
        let result = try ClaudeLanguageModel.parseTranslations(JSONSerialization.data(withJSONObject: response))
        #expect(result == [7: "I give the children an apple."])
    }
}
