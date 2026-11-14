import Foundation
import Testing
import os
@testable import Deutschcoach

private let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "livetest")

/// Calls the real translation with the key stored in the Keychain. Costs money, so it runs only
/// when enabled explicitly:
///   TEST_RUNNER_DEUTSCHCOACH_LIVE_TESTS=1 xcodebuild test … -only-testing:DeutschcoachTests/LiveTranslationTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEUTSCHCOACH_LIVE_TESTS"] == "1"))
struct LiveTranslationTests {
    @Test(.timeLimit(.minutes(2)), arguments: ["en", "zh"])
    func translate(into language: String) async throws {
        let key = try #require(try KeychainStore.apiKey.read(), "No API key in the Keychain")
        let model = ClaudeLanguageModel(client: ClaudeClient(apiKey: { key }))
        let sentences: [(SentenceMode, String)] = [
            (.shadow, "Ich gebe den Kindern einen Apfel."),
            (.cloze, "Am Sonntag stehe ich spät auf."),
            (.recall, "Können Sie mir bitte helfen?"),
            (.recall, "Gestern hast du zu viel Kaffee getrunken."),
            (.shadow, "Wir wohnen seit drei Jahren in Wien."),
        ]
        let request = TranslationRequest(
            nativeLang: language,
            sentences: sentences.enumerated().map { TranslationRequest.Item(id: Int64($0.offset + 1), mode: $0.element.0, de: $0.element.1) }
        )
        let started = ContinuousClock.now
        let result = try await model.translate(request)
        let elapsed = ContinuousClock.now - started
        logger.info("[translate \(language, privacy: .public)] \(elapsed.description, privacy: .public) \(result.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }, privacy: .public)")
        #expect(Set(result.keys) == Set(1...5))
    }
}
