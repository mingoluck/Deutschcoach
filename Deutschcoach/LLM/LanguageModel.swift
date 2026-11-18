import Foundation

// The LLM abstraction (AGENTS.md: LLM calls behind a protocol). Version 0.2 makes no LLM calls
// (DESIGN.md §1); the protocol, the transport client and the error mapping are kept for the
// LLM features planned later (§8).

nonisolated protocol LanguageModel: Sendable {
    var modelName: String { get }

    /// Checks that the API key is present and accepted, without using the model.
    func verifyAccess() async throws
}

// MARK: - Usage

nonisolated struct TokenUsage: Sendable, Equatable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0

    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: a.input + b.input,
            output: a.output + b.output,
            cacheWrite: a.cacheWrite + b.cacheWrite,
            cacheRead: a.cacheRead + b.cacheRead
        )
    }
}

// MARK: - Errors

nonisolated enum LLMError: Error, Equatable, LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case permissionDenied(String)
    case insufficientCredit(String)
    case badRequest(String)
    case rateLimited
    case overloaded
    case server(Int)
    case network(String)
    /// The network monitor reports no connection; nothing was sent.
    case offline
    /// `stop_reason: "refusal"`; the associated value is `stop_details.category` if any.
    case refused(String?)
    /// `stop_reason: "max_tokens"`: the output was cut off.
    case truncated
    /// The model answered without calling the expected tool (named).
    case noToolCall(String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No Claude API key is stored."
        case .invalidAPIKey: "The Claude API key is invalid."
        case .permissionDenied(let message): "The API key lacks permission: \(message)"
        case .insufficientCredit(let message): "Not enough API credit: \(message)"
        case .badRequest(let message): "The API rejected the request: \(message)"
        case .rateLimited: "The Claude API rate limit was hit."
        case .overloaded: "The Claude API is overloaded."
        case .server(let status): "The Claude API returned a server error (\(status))."
        case .network(let message): "Network error: \(message)"
        case .offline: "No network connection."
        case .refused(let category): "The model declined the request\(category.map { " (\($0))" } ?? "")."
        case .truncated: "The model's output was cut off (max_tokens)."
        case .noToolCall(let tool): "The model answered without calling \(tool)."
        case .malformedResponse(let message): "Unexpected API response: \(message)"
        }
    }

    /// Errors worth retrying automatically (DESIGN.md §1: rate limits and server errors).
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .server: true
        default: false
        }
    }
}
