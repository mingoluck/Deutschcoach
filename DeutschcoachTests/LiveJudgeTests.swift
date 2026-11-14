import Foundation
import Testing
import os
@testable import Deutschcoach

private let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "livetest")

/// Calls the real judge with the key stored in the Keychain. Costs money, so it runs only when
/// enabled explicitly:
///   TEST_RUNNER_DEUTSCHCOACH_LIVE_TESTS=1 xcodebuild test … -only-testing:DeutschcoachTests/LiveJudgeTests
/// Latency and verdicts are logged under the "livetest" category.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEUTSCHCOACH_LIVE_TESTS"] == "1"))
struct LiveJudgeTests {
    struct Case: Sendable, CustomStringConvertible {
        var name: String
        var answer: String
        var valid: Bool?
        var used: Set<Int64>?
        var description: String { name }
    }

    static let reference = JudgeRequest(
        mode: .recall,
        translation: "我给孩子们一个苹果。",
        reference: "Ich gebe den Kindern einen Apfel.",
        targets: [
            .init(elementId: 1, title: "geben"),
            .init(elementId: 2, title: "das Kind"),
            .init(elementId: 3, title: "Dativ: indirektes Objekt"),
        ],
        answer: ""
    )

    static let cases = [
        Case(name: "paraphrase", answer: "ich schenke den Kindern einen Apfel", valid: true, used: [2, 3]),
        Case(name: "grammar error", answer: "ich gebe die Kindern ein Apfel", valid: false),
        Case(name: "wrong meaning", answer: "ich esse einen Apfel", valid: false),
        Case(name: "fragment", answer: "ich gebe den", valid: nil, used: nil),
    ]

    @Test(.timeLimit(.minutes(2)), arguments: [false, true], cases)
    func judge(thinking: Bool, _ testCase: Case) async throws {
        let key = try #require(try KeychainStore.apiKey.read(), "No API key in the Keychain")
        var model = ClaudeLanguageModel(client: ClaudeClient(apiKey: { key }))
        model.judgeThinking = thinking
        var request = Self.reference
        request.answer = testCase.answer

        let started = ContinuousClock.now
        let data = try await model.client.send(try model.judgeRequestBody(for: request))
        let elapsed = ContinuousClock.now - started
        let verdict = try ClaudeLanguageModel.parseVerdict(data)
        logger.info("""
            [thinking=\(thinking) \(testCase.name, privacy: .public)] \(elapsed.description, privacy: .public) \
            \(ClaudeLanguageModel.summary(of: data), privacy: .public) \
            verdict valid=\(verdict.valid) confidence=\(verdict.confidence.rawValue, privacy: .public) used=\(verdict.targetsUsed, privacy: .public)
            """)
        if testCase.name == "fragment" {
            #expect(verdict.confidence == .low || !verdict.valid)
        } else {
            #expect(verdict.confidence == .high)
            #expect(verdict.valid == testCase.valid)
            // `targets_used` only matters when valid: Scorer fails every target otherwise.
            if verdict.valid, let used = testCase.used { #expect(Set(verdict.targetsUsed) == used) }
        }
    }
}
