import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "llm")

/// Minimal raw-HTTP client for `POST /v1/messages` (there is no official Swift SDK).
///
/// Rate-limit and server errors are retried twice with increasing delays, honoring
/// `retry-after` (DESIGN.md §1). Everything else is mapped to `LLMError` and thrown.
/// Batch generation streams (`sendStreaming`, DESIGN.md §4.1); the small calls do not.
nonisolated struct ClaudeClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Listing models is free; used to check the key (DESIGN.md §1).
    static let modelsEndpoint = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
    static let apiVersion = "2026-10-21"

    /// Reads the API key at call time, so a key saved later is picked up.
    var apiKey: @Sendable () throws -> String?
    var session: URLSession = .shared
    var maxRetries = 2
    /// Delays before retry 1, 2, … when the server gives no `retry-after`.
    var backoff: [Duration] = [.seconds(2), .seconds(5)]
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Idle timeout. For `send` nothing arrives before the whole response, so it bounds the call
    /// (the judge and translation take seconds); for `sendStreaming`, deltas and `ping` events
    /// keep a long generation alive, so it only detects a dead connection.
    var timeout: TimeInterval = 60

    /// Sends a Messages API request body and returns the response body of a 200.
    func send(_ body: Data) async throws -> Data {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return try await perform(request) { request in
            let (data, response) = try await session.data(for: request)
            let http = try Self.httpResponse(response)
            guard http.statusCode == 200 else { throw StatusFailure(response: http, body: data) }
            return data
        }
    }

    /// Sends a request body with `"stream": true` and returns the reassembled message, in the
    /// same form `send` returns (DESIGN.md §4.1, Transport).
    func sendStreaming(_ body: Data) async throws -> Data {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return try await perform(request) { request in
            let (bytes, response) = try await session.bytes(for: request)
            let http = try Self.httpResponse(response)
            guard http.statusCode == 200 else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                throw StatusFailure(response: http, body: data)
            }
            var assembler = MessageStreamAssembler()
            // Each event is one `data:` line; `lines` drops the blank separators, which is fine.
            for try await line in bytes.lines where line.hasPrefix("data:") {
                try assembler.consume(String(line.dropFirst(5)))
            }
            return try assembler.finish()
        }
    }

    /// Checks that the stored key is accepted (`GET /v1/models`, free). It cannot tell whether
    /// the account has credit; only a Messages call shows that.
    func verifyKey() async throws {
        var request = URLRequest(url: Self.modelsEndpoint, timeoutInterval: 30)
        request.httpMethod = "GET"
        _ = try await perform(request) { request in
            let (data, response) = try await session.data(for: request)
            let http = try Self.httpResponse(response)
            guard http.statusCode == 200 else { throw StatusFailure(response: http, body: data) }
            return data
        }
    }

    /// A non-200 response, for `perform` to map and maybe retry.
    private struct StatusFailure: Error {
        var response: HTTPURLResponse
        var body: Data
    }

    private static func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw LLMError.malformedResponse("not an HTTP response") }
        return http
    }

    /// Adds the auth headers and runs `attempt`, retrying retryable failures: non-200 statuses
    /// and `LLMError`s thrown mid-stream.
    private func perform(_ request: URLRequest, attempt run: (URLRequest) async throws -> Data) async throws -> Data {
        guard let key = try apiKey(), !key.isEmpty else { throw LLMError.missingAPIKey }
        var request = request
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

        var attempt = 0
        while true {
            let error: LLMError
            var retryAfter: Duration?
            do {
                return try await run(request)
            } catch let failure as StatusFailure {
                error = Self.error(status: failure.response.statusCode, body: failure.body)
                retryAfter = Self.retryAfter(failure.response)
                logger.error("Claude API \(failure.response.statusCode, privacy: .public): \(error.localizedDescription, privacy: .public)")
            } catch let failure as LLMError {
                error = failure
                logger.error("Claude API stream: \(error.localizedDescription, privacy: .public)")
            } catch let failure as URLError {
                throw LLMError.network(failure.localizedDescription)
            }
            guard error.isRetryable, attempt < maxRetries else { throw error }
            let delay = retryAfter ?? backoff[min(attempt, backoff.count - 1)]
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
