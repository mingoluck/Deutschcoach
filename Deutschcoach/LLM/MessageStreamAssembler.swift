import Foundation

/// Rebuilds a streamed Messages API response (server-sent events) into the message JSON a
/// non-streaming call returns, so the same parsing code serves both (DESIGN.md §4.1, Transport).
///
/// Feed it the payload of every `data:` line in order, then call `finish()`.
nonisolated struct MessageStreamAssembler {
    private struct Block {
        var object: [String: Any]
        /// Concatenated `input_json_delta` fragments of a `tool_use` block.
        var json = ""
    }

    private var message: [String: Any] = [:]
    private var usage: [String: Any] = [:]
    private var blocks: [Int: Block] = [:]
    private var stopped = false

    /// Consumes the payload of one `data:` line (one event).
    mutating func consume(_ payload: String) throws {
        guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw LLMError.malformedResponse("stream event is not a JSON object")
        }
        switch event["type"] as? String {
        case "message_start":
            message = event["message"] as? [String: Any] ?? [:]
            usage = message["usage"] as? [String: Any] ?? [:]
        case "content_block_start":
            guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else {
                throw LLMError.malformedResponse("content_block_start without index or block")
            }
            blocks[index] = Block(object: block)
        case "content_block_delta":
            guard let index = event["index"] as? Int, blocks[index] != nil, let delta = event["delta"] as? [String: Any] else {
                throw LLMError.malformedResponse("content_block_delta for an unknown block")
            }
            apply(delta, to: index)
        case "message_delta":
            // stop_reason, stop_sequence, stop_details: top-level message fields.
            for (key, value) in event["delta"] as? [String: Any] ?? [:] { message[key] = value }
            // Usage here is cumulative; it overrides the values from message_start.
            for (key, value) in event["usage"] as? [String: Any] ?? [:] { usage[key] = value }
        case "message_stop":
            stopped = true
        case "error":
            throw Self.error(from: event["error"] as? [String: Any] ?? [:])
        default:
            break  // ping, content_block_stop, and event types added later
        }
    }

    private mutating func apply(_ delta: [String: Any], to index: Int) {
        func append(_ key: String, _ text: Any?) {
            guard let text = text as? String else { return }
            blocks[index]!.object[key] = (blocks[index]!.object[key] as? String ?? "") + text
        }
        switch delta["type"] as? String {
        case "input_json_delta":
            blocks[index]!.json += delta["partial_json"] as? String ?? ""
        case "text_delta":
            append("text", delta["text"])
        case "thinking_delta":
            append("thinking", delta["thinking"])
        case "signature_delta":
            blocks[index]!.object["signature"] = delta["signature"]
        default:
            break
        }
    }

    /// The complete message as JSON. Throws if the stream ended before `message_stop`.
    func finish() throws -> Data {
        guard stopped else { throw LLMError.network("The response stream ended early.") }
        // With max_tokens the tool input is cut off mid-JSON; the stop reason reports it instead.
        let truncated = message["stop_reason"] as? String == "max_tokens"
        var content: [[String: Any]] = []
        for index in blocks.keys.sorted() {
            var block = blocks[index]!
            if block.object["type"] as? String == "tool_use" {
                if truncated || block.json.isEmpty {
                    block.object["input"] = block.object["input"] ?? [String: Any]()
                } else {
                    guard let input = try? JSONSerialization.jsonObject(with: Data(block.json.utf8)) else {
                        throw LLMError.malformedResponse("streamed tool input is not valid JSON")
                    }
                    block.object["input"] = input
                }
            }
            content.append(block.object)
        }
        var message = self.message
        message["content"] = content
        message["usage"] = usage
        return try JSONSerialization.data(withJSONObject: message)
    }

    /// Maps an `error` event like the matching HTTP status (`ClaudeClient.error(status:body:)`).
    static func error(from error: [String: Any]) -> LLMError {
        let type = error["type"] as? String ?? "unknown"
        switch type {
        case "overloaded_error": return .overloaded
        case "rate_limit_error": return .rateLimited
        case "api_error": return .server(500)
        default: return .malformedResponse("stream error \(type): \(error["message"] as? String ?? "")")
        }
    }
}
