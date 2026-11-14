import Foundation
import GRDB
import Testing
import os
@testable import Deutschcoach

private let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "livetest")

/// Calls the real Claude API with the key stored in the Keychain. Costs money, so it runs only
/// when enabled explicitly:
///   TEST_RUNNER_DEUTSCHCOACH_LIVE_TESTS=1 xcodebuild test … -only-testing:DeutschcoachTests/LiveGenerationTests
/// Results are logged under the "livetest" category.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEUTSCHCOACH_LIVE_TESTS"] == "1"))
struct LiveGenerationTests {
    struct Variant: Sendable, CustomStringConvertible {
        var effort: String
        var sentences: Int
        var maxTokens: Int
        var description: String { "effort=\(effort) sentences=\(sentences) max_tokens=\(maxTokens)" }
    }

    static let variants = [
        Variant(effort: "medium", sentences: 10, maxTokens: 32_000),
        Variant(effort: "low", sentences: 10, maxTokens: 32_000),
        Variant(effort: "medium", sentences: 5, maxTokens: 32_000),
    ]

    @Test(.timeLimit(.minutes(5)), arguments: variants)
    func measure(_ variant: Variant) async throws {
        let key = try #require(try KeychainStore.apiKey.read(), "No API key in the Keychain")
        let database = try await makeSeededDatabase()
        let request = try await database.writer.read { db in
            try ElementPicker(count: variant.sentences, nativeLang: "zh").makeRequest(from: db)
        }
        var model = ClaudeLanguageModel(client: ClaudeClient(apiKey: { key }, timeout: 300))
        model.effort = variant.effort
        model.maxTokens = variant.maxTokens

        let started = ContinuousClock.now
        let data = try await model.client.send(try model.requestBody(for: request))
        let elapsed = ContinuousClock.now - started
        let summary = ClaudeLanguageModel.summary(of: data)

        let message = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let toolInput = (message["content"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "tool_use" }?["input"]
        let toolBytes = toolInput.map { (try? JSONSerialization.data(withJSONObject: $0).count) ?? 0 } ?? 0

        let response = try ClaudeLanguageModel.parse(data)
        let vocabIds = request.sentences.flatMap(\.targets).filter { $0.kind == .vocab }.map(\.elementId)
        let lexicon = try await database.writer.read { db in try VocabLexicon.load(elementIds: vocabIds, from: db) }
        let validator = SentenceValidator(lexicon: lexicon)
        var failures: [String] = []
        var valid = 0
        for sentenceRequest in request.sentences {
            guard let sentence = response.sentences.first(where: { $0.position == sentenceRequest.position }) else {
                failures.append("#\(sentenceRequest.position) not returned")
                continue
            }
            switch validator.validate(sentence, for: sentenceRequest) {
            case .success: valid += 1
            case .failure(let failure): failures.append("#\(failure.position) \(failure.reason)")
            }
        }

        logger.info("""
            [\(variant.description, privacy: .public)] \(elapsed.description, privacy: .public) \
            \(summary, privacy: .public) tool_input_bytes=\(toolBytes) \
            valid=\(valid)/\(variant.sentences) failures=\(failures, privacy: .public) \
            sample=\(response.sentences.prefix(3).map { "\($0.de) | \($0.translation)" }, privacy: .public)
            """)
        #expect(valid >= variant.sentences - 2)
    }
}
