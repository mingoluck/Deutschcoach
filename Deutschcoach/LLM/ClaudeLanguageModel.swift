import Foundation

/// The Claude Messages API behind `LanguageModel` (DESIGN.md §1). Unused in version 0.2; kept
/// with the response helpers for the LLM features planned later (§8).
nonisolated struct ClaudeLanguageModel: LanguageModel {
    static let defaultModel = "claude-haiku-5-5"

    var model = defaultModel
    var client: ClaudeClient

    var modelName: String { model }

    func verifyAccess() async throws {
        try await client.verifyKey()
    }

    // MARK: - Response

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

    static func usage(from message: [String: Any]) -> TokenUsage {
        let usage = message["usage"] as? [String: Any] ?? [:]
        return TokenUsage(
            input: usage["input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0,
            cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0
        )
    }
}
