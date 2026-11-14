import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "llm")

/// Minimal raw-HTTP client for `POST /v1/messages` (there is no official Swift SDK).
///
/// Rate-limit and server errors are retried twice with increasing delays, honoring
/// `retry-after` (DESIGN.md §1). Everything else is mapped to `LLMError` and thrown.
nonisolated struct ClaudeClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"

    /// Reads the API key at call time, so a key saved later is picked up.
    var apiKey: @Sendable () throws -> String?
    var session: URLSession = .shared
    var maxRetries = 2
    /// Delays before retry 1, 2, … when the server gives no `retry-after`.
    var backoff: [Duration] = [.seconds(2), .seconds(5)]
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// A full batch takes about a minute (up to 32K output tokens), so allow well beyond that.
    var timeout: TimeInterval = 300

    /// Sends a Messages API request body and returns the response body of a 200.
    func send(_ body: Data) async throws -> Data {
        guard let key = try apiKey(), !key.isEmpty else { throw LLMError.missingAPIKey }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

        var attempt = 0
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError {
                throw LLMError.network(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else {
                throw LLMError.malformedResponse("not an HTTP response")
            }
            if http.statusCode == 200 { return data }

            let error = Self.error(status: http.statusCode, body: data)
            logger.error("Claude API \(http.statusCode, privacy: .public): \(error.localizedDescription, privacy: .public)")
            guard error.isRetryable, attempt < maxRetries else { throw error }
            let delay = Self.retryAfter(http) ?? backoff[min(attempt, backoff.count - 1)]
            attempt += 1
            logger.info("Retrying in \(delay.description, privacy: .public) (attempt \(attempt + 1))")
            try await sleep(delay)
        }
    }

    // MARK: - Errors

    static func error(status: Int, body: Data) -> LLMError {
        let message = errorMessage(body) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 401: return .invalidAPIKey
        case 403: return .permissionDenied(message)
        case 400 where message.localizedCaseInsensitiveContains("credit"): return .insufficientCredit(message)
        case 400...499 where status != 429: return .badRequest(message)
        case 429: return .rateLimited
        case 529: return .overloaded
        default: return .server(status)
        }
    }

    /// `{"type": "error", "error": {"type": "...", "message": "..."}}`
    private static func errorMessage(_ body: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let error = object["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard
            let value = response.value(forHTTPHeaderField: "retry-after"),
            let seconds = Double(value.trimmingCharacters(in: .whitespaces)),
            seconds >= 0
        else { return nil }
        return .seconds(min(seconds, 60))
    }
}
