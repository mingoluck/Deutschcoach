import Foundation
import Synchronization
import Testing
@testable import Deutschcoach

// MARK: - Request and schema

struct GenerationRequestTests {
    @Test func encodesTheDesignShape() throws {
        let request = GenerationRequest(nativeLang: "zh", userLevel: .a2, sentences: [
            SentenceRequest(position: 1, mode: .shadow, targets: [
                GenerationTarget(elementId: 101, kind: .vocab, title: "geben"),
                GenerationTarget(elementId: 102, kind: .vocab, title: "die Bank", sense: "Sitzmöbel"),
            ]),
        ])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        #expect(object["native_lang"] as? String == "zh")
        #expect(object["user_level"] as? String == "A2")
        let sentence = (object["sentences"] as! [[String: Any]])[0]
        #expect(sentence["position"] as? Int == 1)
        #expect(sentence["mode"] as? String == "shadow")
        let targets = sentence["targets"] as! [[String: Any]]
        #expect(Set(targets[0].keys) == ["element_id", "kind", "title"])  // sense omitted when nil
        #expect(targets[1]["sense"] as? String == "Sitzmöbel")
    }

    @Test func requestBodyFollowsTheAPIRules() throws {
        let model = ClaudeLanguageModel(client: ClaudeClient(apiKey: { "test" }))
        let request = GenerationRequest(nativeLang: "zh", userLevel: .a1, sentences: [])
        let body = try JSONSerialization.jsonObject(with: model.requestBody(for: request)) as! [String: Any]

        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect(body["max_tokens"] as? Int == 32_000)
        // No sampling parameters: they return a 400 on this model.
        #expect(body["temperature"] == nil && body["top_p"] == nil && body["top_k"] == nil)
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        let toolChoice = body["tool_choice"] as! [String: Any]
        #expect(toolChoice["type"] as? String == "auto")
        #expect(toolChoice["disable_parallel_tool_use"] as? Bool == true)

        let system = (body["system"] as! [[String: Any]])[0]
        #expect((system["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        let tool = (body["tools"] as! [[String: Any]])[0]
        #expect(tool["name"] as? String == "submit_sentences")
        #expect(tool["strict"] as? Bool == true)

        let message = (body["messages"] as! [[String: Any]]).last!
        #expect(message["role"] as? String == "user")
        let text = ((message["content"] as! [[String: Any]])[0]["text"] as! String)
        #expect(text.contains(#""native_lang":"zh""#))
    }

    @Test func cachedPrefixIsStable() throws {
        let model = ClaudeLanguageModel(client: ClaudeClient(apiKey: { "test" }))
        let a = GenerationRequest(nativeLang: "zh", userLevel: .a1, sentences: [])
        let b = GenerationRequest(nativeLang: "zh", userLevel: .a2, sentences: [])
        let first = try JSONSerialization.jsonObject(with: model.requestBody(for: a)) as! [String: Any]
        let second = try JSONSerialization.jsonObject(with: model.requestBody(for: b)) as! [String: Any]
        let tools = { (body: [String: Any]) in try JSONSerialization.data(withJSONObject: body["tools"]!, options: .sortedKeys) }
        let system = { (body: [String: Any]) in try JSONSerialization.data(withJSONObject: body["system"]!, options: .sortedKeys) }
        #expect(try tools(first) == tools(second))
        #expect(try system(first) == system(second))
    }

    /// Strict tools need `additionalProperties: false` and every property required, on every object.
    @Test func toolSchemaIsStrictCompatible() {
        func check(_ schema: [String: Any], path: String) {
            if schema["type"] as? String == "object" {
                let properties = schema["properties"] as? [String: Any] ?? [:]
                #expect(schema["additionalProperties"] as? Bool == false, "\(path)")
                #expect(Set(schema["required"] as? [String] ?? []) == Set(properties.keys), "\(path)")
                for (name, child) in properties {
                    check(child as! [String: Any], path: "\(path).\(name)")
                }
            }
            if let items = schema["items"] as? [String: Any] {
                check(items, path: "\(path)[]")
            }
            for unsupported in ["minItems", "maxItems", "minLength", "maxLength", "minimum", "maximum"] {
                #expect(schema[unsupported] == nil, "\(path) uses \(unsupported)")
            }
        }
        check(GenerationPrompt.tool["input_schema"] as! [String: Any], path: "input")
    }

    @Test func systemPromptCarriesWordLimitsAndLabels() {
        for (level, limit) in GenerationPrompt.wordLimits {
            #expect(GenerationPrompt.system.contains("\(level.rawValue) \(limit)"))
        }
        for code in Constituent.allCases.map(\.rawValue) + ClauseKind.allCases.map(\.rawValue) + PartOfSpeech.allCases.map(\.rawValue) {
            #expect(GenerationPrompt.system.contains(code), "\(code)")
        }
    }
}

// MARK: - Response parsing

struct ResponseParsingTests {
    private func response(content: [[String: Any]], stopReason: String = "tool_use", extra: [String: Any] = [:]) throws -> Data {
        var message: [String: Any] = [
            "type": "message",
            "role": "assistant",
            "content": content,
            "stop_reason": stopReason,
            "usage": ["input_tokens": 120, "output_tokens": 900, "cache_creation_input_tokens": 3000, "cache_read_input_tokens": 0],
        ]
        message.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: message)
    }

    private let validEntry: [String: Any] = [
        "position": 1, "de": "Ja.", "translation": "是。",
        "words": [["Ja", "ja", "INTJ", ""], [".", "", "PUNCT", ""]],
        "spans": [], "targets": [["element_id": 7, "tokens": [0]]],
    ]

    @Test func readsToolCallAfterThinkingBlocks() throws {
        let data = try response(content: [
            ["type": "thinking", "thinking": "", "signature": "abc"],
            ["type": "tool_use", "id": "toolu_1", "name": "submit_sentences", "input": ["sentences": [validEntry]]],
        ])
        let parsed = try ClaudeLanguageModel.parse(data)
        #expect(parsed.sentences.count == 1)
        #expect(parsed.sentences[0].targets == [TargetTokens(elementId: 7, tokens: [0])])
        #expect(parsed.usage == TokenUsage(input: 120, output: 900, cacheWrite: 3000, cacheRead: 0))
    }

    @Test func malformedEntryDoesNotSpoilTheOthers() throws {
        var broken = validEntry
        broken["position"] = 2
        broken["words"] = "not an array"
        let data = try response(content: [
            ["type": "tool_use", "id": "toolu_1", "name": "submit_sentences", "input": ["sentences": [validEntry, broken]]],
        ])
        let parsed = try ClaudeLanguageModel.parse(data)
        #expect(parsed.sentences.map(\.position) == [1])
        #expect(parsed.malformed.map(\.position) == [2])
    }

    @Test func refusal() throws {
        let data = try response(content: [], stopReason: "refusal", extra: ["stop_details": ["type": "refusal", "category": "general_harms"]])
        #expect(throws: LLMError.refused("general_harms")) { try ClaudeLanguageModel.parse(data) }
    }

    @Test func truncatedOutput() throws {
        let data = try response(content: [["type": "thinking", "thinking": "", "signature": "x"]], stopReason: "max_tokens")
        #expect(throws: LLMError.truncated) { try ClaudeLanguageModel.parse(data) }
    }

    @Test func answerWithoutToolCall() throws {
        let data = try response(content: [["type": "text", "text": "Here you go"]], stopReason: "end_turn")
        #expect(throws: LLMError.noToolCall(GenerationPrompt.toolName)) { try ClaudeLanguageModel.parse(data) }
    }
}

// MARK: - HTTP client

/// Serves scripted responses to `ClaudeClient` and records the requests.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: String = "{}"
    }

    static let replies = Mutex<[Reply]>([])
    static let requests = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let reply = Self.replies.withLock { $0.isEmpty ? Reply(status: 500) : $0.removeFirst() }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SleepRecorder: Sendable {
    let durations = Mutex<[Duration]>([])
}

@Suite(.serialized)
struct ClaudeClientTests {
    private let recorder = SleepRecorder()
    private var sleeps: [Duration] { recorder.durations.withLock { $0 } }

    private func client(key: String? = "sk-test", replies: [StubURLProtocol.Reply]) -> ClaudeClient {
        StubURLProtocol.replies.withLock { $0 = replies }
        StubURLProtocol.requests.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let recorder = self.recorder
        return ClaudeClient(
            apiKey: { key },
            session: URLSession(configuration: configuration),
            sleep: { duration in recorder.durations.withLock { $0.append(duration) } }
        )
    }

    private var requestCount: Int { StubURLProtocol.requests.withLock { $0.count } }

    @Test func sendsTheRequiredHeaders() async throws {
        let client = client(replies: [.init(status: 200, body: #"{"ok":true}"#)])
        let data = try await client.send(Data("{}".utf8))
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
        let request = try #require(StubURLProtocol.requests.withLock { $0.first })
        #expect(request.url == ClaudeClient.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    @Test func retriesOverloadedTwiceWithIncreasingDelays() async throws {
        let client = client(replies: [.init(status: 529), .init(status: 529), .init(status: 200)])
        _ = try await client.send(Data())
        #expect(requestCount == 3)
        #expect(sleeps == [.seconds(2), .seconds(5)])
    }

    @Test func givesUpAfterTwoRetries() async throws {
        let client = client(replies: [.init(status: 500), .init(status: 503), .init(status: 529)])
        await #expect(throws: LLMError.overloaded) { try await client.send(Data()) }
        #expect(requestCount == 3)
    }

    @Test func honorsRetryAfter() async throws {
        let client = client(replies: [.init(status: 429, headers: ["retry-after": "7"]), .init(status: 200)])
        _ = try await client.send(Data())
        #expect(sleeps == [.seconds(7)])
    }

    @Test func doesNotRetryClientErrors() async throws {
        let unauthorized = client(replies: [.init(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)])
        await #expect(throws: LLMError.invalidAPIKey) { try await unauthorized.send(Data()) }
        #expect(requestCount == 1)

        let broke = client(replies: [.init(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low"}}"#)])
        await #expect(throws: LLMError.insufficientCredit("Your credit balance is too low")) { try await broke.send(Data()) }
        #expect(requestCount == 1)
    }

    @Test func missingKeySendsNothing() async throws {
        let client = client(key: nil, replies: [.init(status: 200)])
        await #expect(throws: LLMError.missingAPIKey) { try await client.send(Data()) }
        #expect(requestCount == 0)
    }
}

// MARK: - Keychain

struct KeychainStoreTests {
    @Test func roundTrip() throws {
        let store = KeychainStore(service: "com.ming.Deutschcoach.tests", account: "roundtrip-\(UUID().uuidString)")
        defer { try? store.delete() }
        #expect(try store.read() == nil)
        try store.save("first")
        #expect(try store.read() == "first")
        try store.save("second")  // update in place
        #expect(try store.read() == "second")
        try store.delete()
        #expect(try store.read() == nil)
        try store.delete()  // deleting a missing item is fine
    }
}
