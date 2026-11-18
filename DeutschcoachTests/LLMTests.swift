import Foundation
import Synchronization
import Testing
@testable import Deutschcoach

// MARK: - Response parsing

/// The sentence texts in the input of the `SSE.tool` call.
private func parse(_ data: Data) throws -> [String] {
    let (_, input) = try ClaudeLanguageModel.toolInput(in: data, tool: SSE.tool)
    return (input["sentences"] as? [[String: Any]] ?? []).compactMap { $0["de"] as? String }
}

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

    @Test func readsToolCallAfterThinkingBlocks() throws {
        let data = try response(content: [
            ["type": "thinking", "thinking": "", "signature": "abc"],
            ["type": "tool_use", "id": "toolu_1", "name": SSE.tool, "input": ["sentences": [SSE.entry]]],
        ])
        let (message, input) = try ClaudeLanguageModel.toolInput(in: data, tool: SSE.tool)
        #expect((input["sentences"] as? [Any])?.count == 1)
        #expect(ClaudeLanguageModel.usage(from: message) == TokenUsage(input: 120, output: 900, cacheWrite: 3000, cacheRead: 0))
    }

    @Test func refusal() throws {
        let data = try response(content: [], stopReason: "refusal", extra: ["stop_details": ["type": "refusal", "category": "general_harms"]])
        #expect(throws: LLMError.refused("general_harms")) { try parse(data) }
    }

    @Test func truncatedOutput() throws {
        let data = try response(content: [["type": "thinking", "thinking": "", "signature": "x"]], stopReason: "max_tokens")
        #expect(throws: LLMError.truncated) { try parse(data) }
    }

    @Test func answerWithoutToolCall() throws {
        let data = try response(content: [["type": "text", "text": "Here you go"]], stopReason: "end_turn")
        #expect(throws: LLMError.noToolCall(SSE.tool)) { try parse(data) }
    }
}

// MARK: - Stream reassembly

/// Server-sent events as the Messages API streams them.
enum SSE {
    static let tool = "submit_sentences"

    static func text(_ events: [[String: Any]]) -> String {
        events.map { event in
            let data = try! JSONSerialization.data(withJSONObject: event)
            return "event: \(event["type"] as! String)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
        }.joined()
    }

    /// `data:` payloads only, for feeding `MessageStreamAssembler` directly.
    static func payloads(_ events: [[String: Any]]) -> [String] {
        events.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
    }

    static var start: [String: Any] { [
        "type": "message_start",
        "message": [
            "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-haiku-5-5",
            "content": [], "stop_reason": NSNull(),
            "usage": ["input_tokens": 120, "output_tokens": 1, "cache_creation_input_tokens": 3000, "cache_read_input_tokens": 0],
        ] as [String: Any],
    ] }

    static var thinking: [[String: Any]] { [
        ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
        ["type": "ping"],
        ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "sig"]],
        ["type": "content_block_stop", "index": 0],
    ] }

    /// A tool_use block at index 1 whose input JSON arrives in `size`-character fragments.
    static func toolUse(_ input: Any, fragment size: Int = 7) -> [[String: Any]] {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        var fragments: [String] = []
        var rest = Substring(json)
        while !rest.isEmpty {
            fragments.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return [["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "toolu_1", "name": "submit_sentences", "input": [:]]]]
            + fragments.map { ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": $0]] }
            + [["type": "content_block_stop", "index": 1]]
    }

    static func end(_ stopReason: String, output: Int = 900) -> [[String: Any]] {
        [
            ["type": "message_delta", "delta": ["stop_reason": stopReason, "stop_sequence": NSNull()], "usage": ["output_tokens": output]],
            ["type": "message_stop"],
        ]
    }

    static var entry: [String: Any] { [
        "position": 1, "de": "Grüß dich.", "translation": "你好。",
        "words": [["Grüß", "grüßen", "VERB", ""], ["dich", "du", "PRON", ""], [".", "", "PUNCT", ""]],
        "spans": [], "targets": [["element_id": 7, "tokens": [0]]],
    ] }
}

struct MessageStreamAssemblerTests {
    private func assemble(_ events: [[String: Any]]) throws -> Data {
        var assembler = MessageStreamAssembler()
        for payload in SSE.payloads(events) { try assembler.consume(payload) }
        return try assembler.finish()
    }

    @Test func rebuildsTheNonStreamingMessage() throws {
        // 3-character fragments split "Grüß" and "你好" across deltas.
        let data = try assemble([SSE.start] + SSE.thinking + SSE.toolUse(["sentences": [SSE.entry]], fragment: 3) + SSE.end("tool_use"))
        let message = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(message["stop_reason"] as? String == "tool_use")
        let blocks = message["content"] as! [[String: Any]]
        #expect(blocks.map { $0["type"] as! String } == ["thinking", "tool_use"])
        #expect(blocks[0]["signature"] as? String == "sig")

        #expect(try parse(data) == ["Grüß dich."])
        // Input and cache from message_start, output from message_delta.
        #expect(ClaudeLanguageModel.usage(from: message) == TokenUsage(input: 120, output: 900, cacheWrite: 3000, cacheRead: 0))
    }

    @Test func truncationIsReportedAsTruncation() throws {
        // The tool input is cut off mid-JSON; parsing must report max_tokens, not bad JSON.
        var tool = SSE.toolUse(["sentences": [SSE.entry]])
        tool.removeLast(3)
        let data = try assemble([SSE.start] + SSE.thinking + tool + SSE.end("max_tokens", output: 64_000))
        #expect(throws: LLMError.truncated) { try parse(data) }
        #expect(ClaudeLanguageModel.summary(of: data).contains("stop_reason=max_tokens"))
    }

    @Test func refusalKeepsItsDetails() throws {
        let end: [[String: Any]] = [
            ["type": "message_delta", "delta": ["stop_reason": "refusal", "stop_details": ["type": "refusal", "category": "general_harms"]], "usage": ["output_tokens": 5]],
            ["type": "message_stop"],
        ]
        let data = try assemble([SSE.start] + end)
        #expect(throws: LLMError.refused("general_harms")) { try parse(data) }
    }

    @Test func streamWithoutMessageStopIsANetworkError() throws {
        var events = [SSE.start] + SSE.thinking + SSE.toolUse(["sentences": [SSE.entry]]) + SSE.end("tool_use")
        events.removeLast()
        #expect(throws: LLMError.network("The response stream ended early.")) { try assemble(events) }
    }

    @Test func errorEventsMapLikeHTTPErrors() throws {
        func error(_ type: String) -> [[String: Any]] {
            [SSE.start, ["type": "error", "error": ["type": type, "message": "x"]]]
        }
        #expect(throws: LLMError.overloaded) { try assemble(error("overloaded_error")) }
        #expect(throws: LLMError.rateLimited) { try assemble(error("rate_limit_error")) }
        #expect(throws: LLMError.server(500)) { try assemble(error("api_error")) }
        #expect(throws: LLMError.malformedResponse("stream error invalid_request_error: x")) { try assemble(error("invalid_request_error")) }
    }

    @Test func ignoresUnknownEvents() throws {
        let data = try assemble([SSE.start, ["type": "ping"], ["type": "something_new", "index": 9]]
            + SSE.toolUse(["sentences": [SSE.entry]]) + SSE.end("tool_use"))
        #expect(try parse(data).count == 1)
    }

    @Test func textBlocksAreConcatenated() throws {
        let data = try assemble([SSE.start,
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Here "]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "you go"]],
            ["type": "content_block_stop", "index": 0],
        ] + SSE.end("end_turn"))
        let message = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((message["content"] as! [[String: Any]])[0]["text"] as? String == "Here you go")
        #expect(throws: LLMError.noToolCall(SSE.tool)) { try parse(data) }
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

    // MARK: Streaming

    private var streamed: String {
        SSE.text([SSE.start] + SSE.thinking + SSE.toolUse(["sentences": [SSE.entry]]) + SSE.end("tool_use"))
    }

    @Test func streamingReturnsTheReassembledMessage() async throws {
        let client = client(replies: [.init(status: 200, headers: ["content-type": "text/event-stream"], body: streamed)])
        let data = try await client.sendStreaming(Data("{}".utf8))
        #expect(try parse(data) == ["Grüß dich."])
        let request = try #require(StubURLProtocol.requests.withLock { $0.first })
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    }

    @Test func streamingRetriesOverloadedStatus() async throws {
        let client = client(replies: [.init(status: 529), .init(status: 529), .init(status: 200, body: streamed)])
        _ = try await client.sendStreaming(Data())
        #expect(requestCount == 3)
        #expect(sleeps == [.seconds(2), .seconds(5)])
    }

    @Test func streamingRetriesAnErrorEventMidStream() async throws {
        let failing = SSE.text([SSE.start] + SSE.thinking + [["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]]])
        let client = client(replies: [.init(status: 200, body: failing), .init(status: 200, body: streamed)])
        _ = try await client.sendStreaming(Data())
        #expect(requestCount == 2)
        #expect(sleeps == [.seconds(2)])
    }

    @Test func streamingDoesNotRetryAnEarlyEnd() async throws {
        let cut = SSE.text([SSE.start] + SSE.thinking)
        let client = client(replies: [.init(status: 200, body: cut), .init(status: 200, body: streamed)])
        await #expect(throws: LLMError.network("The response stream ended early.")) { try await client.sendStreaming(Data()) }
        #expect(requestCount == 1)
    }

    @Test func streamingMapsClientErrors() async throws {
        let client = client(replies: [.init(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)])
        await #expect(throws: LLMError.invalidAPIKey) { try await client.sendStreaming(Data()) }
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
