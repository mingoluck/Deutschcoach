import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "llm")

/// Sentence generation with the Claude Messages API (DESIGN.md §4.1).
nonisolated struct ClaudeLanguageModel: LanguageModel {
    /// DESIGN.md §1: Haiku-class first; revisit after measuring quality and cost.
    static let defaultModel = "claude-haiku-5-5"

    var model = defaultModel
    /// Thinking depth. `claude-haiku-5-5` defaults to `medium`; set explicitly.
    var effort = "medium"
    /// Includes thinking tokens, which are most of the output. Measured for 10 sentences:
    /// 12.4K–17.8K output tokens (tool input only ~2–3K), 48–68 s; 16K truncated batches.
    /// Non-streaming; `ClaudeClient.timeout` leaves room for the slowest case.
    var maxTokens = 32_000
    /// The judge's task is small and the user waits for it (§3.4): low effort, no thinking.
    var judgeEffort = "low"
    var judgeThinking = false
    var client: ClaudeClient

    var modelName: String { model }

    func generateSentences(_ request: GenerationRequest) async throws -> GenerationResponse {
        let body = try requestBody(for: request)
        let started = ContinuousClock.now
        let data = try await client.send(body)
        logger.info("Response after \((ContinuousClock.now - started).description, privacy: .public): \(Self.summary(of: data), privacy: .public)")
        let response: GenerationResponse
        do {
            response = try Self.parse(data)
        } catch {
            logger.error("Unusable response: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        logger.info("""
            Generated \(response.sentences.count) sentences (\(response.malformed.count) malformed); \
            tokens in \(response.usage.input) out \(response.usage.output) \
            cache write \(response.usage.cacheWrite) read \(response.usage.cacheRead)
            """)
        return response
    }

    // MARK: - Request

    func requestBody(for request: GenerationRequest) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            // Cached prefix: tools + system (render order tools → system → messages).
            "system": [
                ["type": "text", "text": GenerationPrompt.system, "cache_control": ["type": "ephemeral"]],
            ],
            "tools": [GenerationPrompt.tool],
            // Not forced: a forced tool call skips thinking (DESIGN.md §4.1). At most one call.
            "tool_choice": ["type": "auto", "disable_parallel_tool_use": true],
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": effort],
            "messages": [
                ["role": "user", "content": [["type": "text", "text": try GenerationPrompt.userMessage(for: request)]]],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Response

    /// Parses a Messages API response. Content blocks are read by type: thinking blocks come first.
    static func parse(_ data: Data) throws -> GenerationResponse {
        let (message, input) = try toolInput(in: data, tool: GenerationPrompt.toolName)
        guard let entries = input["sentences"] as? [Any] else {
            throw LLMError.malformedResponse("tool input has no sentences array")
        }

        var sentences: [GeneratedSentence] = []
        var malformed: [MalformedSentence] = []
        let decoder = JSONDecoder()
        for entry in entries {
            let position = (entry as? [String: Any])?["position"] as? Int
            do {
                let json = try JSONSerialization.data(withJSONObject: entry)
                sentences.append(try decoder.decode(GeneratedSentence.self, from: json))
            } catch {
                malformed.append(MalformedSentence(position: position, reason: "could not decode: \(error)"))
            }
        }
        return GenerationResponse(sentences: sentences, malformed: malformed, usage: usage(from: message))
    }

    /// The message object and the input of the call to `tool`, after checking the stop reason.
    static func toolInput(in data: Data, tool: String) throws -> (message: [String: Any], input: [String: Any]) {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.malformedResponse("response is not a JSON object")
        }
        let stopReason = message["stop_reason"] as? String
        if stopReason == "refusal" {
            let details = message["stop_details"] as? [String: Any]
            throw LLMError.refused(details?["category"] as? String)
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        let toolCall = blocks.first { $0["type"] as? String == "tool_use" && $0["name"] as? String == tool }
        guard let toolCall else {
            throw stopReason == "max_tokens" ? LLMError.truncated : LLMError.noToolCall(tool)
        }
        // With max_tokens the tool input may be incomplete.
        if stopReason == "max_tokens" { throw LLMError.truncated }
        guard let input = toolCall["input"] as? [String: Any] else {
            throw LLMError.malformedResponse("\(tool) has no input object")
        }
        return (message, input)
    }

    // MARK: - Judge (§3.4)

    func judge(_ request: JudgeRequest) async throws -> JudgeVerdict {
        let started = ContinuousClock.now
        let data = try await client.send(try judgeRequestBody(for: request))
        logger.info("Judge response after \((ContinuousClock.now - started).description, privacy: .public): \(Self.summary(of: data), privacy: .public)")
        let verdict = try Self.parseVerdict(data)
        logger.info("Verdict valid=\(verdict.valid) confidence=\(verdict.confidence.rawValue, privacy: .public) used=\(verdict.targetsUsed, privacy: .public)")
        return verdict
    }

    func judgeRequestBody(for request: JudgeRequest) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "system": [["type": "text", "text": JudgePrompt.system]],
            "tools": [JudgePrompt.tool],
            "output_config": ["effort": judgeEffort],
            "messages": [
                ["role": "user", "content": [["type": "text", "text": try JudgePrompt.userMessage(for: request)]]],
            ],
        ]
        if judgeThinking {
            body["thinking"] = ["type": "adaptive"]
            body["tool_choice"] = ["type": "auto", "disable_parallel_tool_use": true]
            body["max_tokens"] = 8_000
        } else {
            // Without thinking the tool call can be forced; the user is waiting for the verdict.
            body["thinking"] = ["type": "disabled"]
            body["tool_choice"] = ["type": "tool", "name": JudgePrompt.toolName, "disable_parallel_tool_use": true]
            body["max_tokens"] = 1_024
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func parseVerdict(_ data: Data) throws -> JudgeVerdict {
        let (_, input) = try toolInput(in: data, tool: JudgePrompt.toolName)
        do {
            return try JSONDecoder().decode(JudgeVerdict.self, from: JSONSerialization.data(withJSONObject: input))
        } catch {
            throw LLMError.malformedResponse("could not decode the verdict: \(error)")
        }
    }

    func verifyAccess() async throws {
        try await client.verifyKey()
    }

    // MARK: - Translation (§3.1)

    func translate(_ request: TranslationRequest) async throws -> [Int64: String] {
        let started = ContinuousClock.now
        let data = try await client.send(try translationRequestBody(for: request))
        logger.info("Translation response after \((ContinuousClock.now - started).description, privacy: .public): \(Self.summary(of: data), privacy: .public)")
        return try Self.parseTranslations(data)
    }

    /// Same settings as the judge: low effort, thinking off, forced tool call.
    func translationRequestBody(for request: TranslationRequest) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4_096,
            "system": [["type": "text", "text": TranslationPrompt.system]],
            "tools": [TranslationPrompt.tool],
            "tool_choice": ["type": "tool", "name": TranslationPrompt.toolName, "disable_parallel_tool_use": true],
            "thinking": ["type": "disabled"],
            "output_config": ["effort": judgeEffort],
            "messages": [
                ["role": "user", "content": [["type": "text", "text": try TranslationPrompt.userMessage(for: request)]]],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func parseTranslations(_ data: Data) throws -> [Int64: String] {
        let (_, input) = try toolInput(in: data, tool: TranslationPrompt.toolName)
        guard let entries = input["translations"] as? [[String: Any]] else {
            throw LLMError.malformedResponse("tool input has no translations array")
        }
        var result: [Int64: String] = [:]
        for entry in entries {
            guard let id = (entry["id"] as? NSNumber)?.int64Value, let text = entry["translation"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result[id] = trimmed }
        }
        return result
    }

    // MARK: - Diagnostics

    /// stop_reason, usage and content block types, for diagnosis (no message text).
    static func summary(of data: Data) -> String {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "not JSON (\(data.count) bytes)"
        }
        let blocks = (message["content"] as? [[String: Any]] ?? []).map { $0["type"] as? String ?? "?" }
        let usage = usage(from: message)
        return "stop_reason=\(message["stop_reason"] as? String ?? "nil") blocks=\(blocks) "
            + "tokens in \(usage.input) out \(usage.output) cache write \(usage.cacheWrite) read \(usage.cacheRead)"
    }

    private static func usage(from message: [String: Any]) -> TokenUsage {
        let usage = message["usage"] as? [String: Any] ?? [:]
        return TokenUsage(
            input: usage["input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0,
            cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0
        )
    }
}
