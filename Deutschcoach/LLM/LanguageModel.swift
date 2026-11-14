import Foundation

// The LLM abstraction (AGENTS.md: LLM calls behind a protocol) and the data exchanged for
// sentence generation (DESIGN.md §4.1). The judge (M5) and translation (M6) are added later.

nonisolated protocol LanguageModel: Sendable {
    /// Recorded in `batch.model` and `sentence.model`.
    var modelName: String { get }

    func generateSentences(_ request: GenerationRequest) async throws -> GenerationResponse
}

// MARK: - Request (§4.1)

nonisolated struct GenerationRequest: Codable, Sendable, Equatable {
    var nativeLang: String
    var userLevel: CEFRLevel
    var sentences: [SentenceRequest]

    enum CodingKeys: String, CodingKey {
        case nativeLang = "native_lang"
        case userLevel = "user_level"
        case sentences
    }
}

nonisolated struct SentenceRequest: Codable, Sendable, Equatable {
    var position: Int
    var mode: SentenceMode
    var targets: [GenerationTarget]
}

nonisolated struct GenerationTarget: Codable, Sendable, Equatable {
    var elementId: Int64
    var kind: ElementKind
    var title: String
    /// Disambiguation for polysemous vocabulary; omitted when nil.
    var sense: String?

    enum CodingKeys: String, CodingKey {
        case elementId = "element_id"
        case kind, title, sense
    }
}

// MARK: - Response (§4.1)

/// One sentence as returned by the model, before validation. `words` stays raw so that a
/// malformed row fails validation for that sentence only.
nonisolated struct GeneratedSentence: Codable, Sendable, Equatable {
    var position: Int
    var de: String
    var translation: String
    var words: [[String]]
    var spans: [AnnotationSpan]
    var targets: [TargetTokens]
}

nonisolated struct TargetTokens: Codable, Sendable, Equatable {
    var elementId: Int64
    var tokens: [Int]

    enum CodingKeys: String, CodingKey {
        case elementId = "element_id"
        case tokens
    }
}

/// A sentence that could not even be decoded (wrong field types, missing fields).
nonisolated struct MalformedSentence: Sendable, Equatable {
    var position: Int?
    var reason: String
}

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

nonisolated struct GenerationResponse: Sendable, Equatable {
    var sentences: [GeneratedSentence]
    var malformed: [MalformedSentence]
    var usage: TokenUsage
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
    /// `stop_reason: "refusal"`; the associated value is `stop_details.category` if any.
    case refused(String?)
    /// `stop_reason: "max_tokens"`: the output was cut off.
    case truncated
    /// The model answered without calling the tool.
    case noToolCall
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
        case .refused(let category): "The model declined the request\(category.map { " (\($0))" } ?? "")."
        case .truncated: "The model's output was cut off (max_tokens)."
        case .noToolCall: "The model answered without calling submit_sentences."
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
