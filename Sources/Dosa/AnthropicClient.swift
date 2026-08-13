import Foundation

/// Minimal client for the Anthropic Messages API (https://api.anthropic.com).
/// Text-only: Claude has no audio input, so transcription always uses the
/// engine picked in Settings → Transcription, never this client.
///
/// Raw HTTP rather than an SDK because Anthropic ships no official Swift SDK.
struct AnthropicClient {
    let apiKey: String
    let model: String

    private static let base = "https://api.anthropic.com"
    private static let apiVersion = "2023-06-01"

    /// Generous enough for a long set of meeting notes without risking a
    /// truncated response mid-section. On the models that think, this budget
    /// covers thinking *and* the reply, so it's sized well above what notes
    /// alone need. Kept under ~16K so the non-streaming request can't hit an
    /// HTTP timeout.
    private static let maxTokens = 16_000

    enum AnthropicError: LocalizedError, DetailedError {
        case http(Int, String)
        case malformedResponse(String)
        case refused(String)
        case truncated(String)

        var errorDescription: String? {
            switch self {
            case .http(401, _):
                return "Anthropic rejected your API key. Check it in Settings → LLM Provider → Anthropic, or generate a new one at platform.claude.com/settings/keys."
            case .http(let status, _):
                return "The Anthropic API returned an error (HTTP \(status))."
            case .malformedResponse:
                return "Anthropic returned an unexpected response."
            case .refused:
                return "Claude declined to generate notes for this recording."
            case .truncated:
                return "Claude ran out of room before writing any notes — the meeting may be too long for this model. Try claude-haiku-4-5 in Settings → LLM Provider → Anthropic, which spends less of its budget on reasoning."
            }
        }

        var errorDetail: String? {
            switch self {
            case .http(_, let body), .malformedResponse(let body),
                 .refused(let body), .truncated(let body):
                return body.isEmpty ? nil : String(body.prefix(4000))
            }
        }
    }

    func generateText(prompt: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Self.base)/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        // `thinking` and `effort` are deliberately omitted: neither is
        // supported on Haiku 4.5 (the default), and sending them would 400
        // there. Left unset, each model does the right thing on its own —
        // Haiku answers directly, Sonnet 5 and Opus 5 think adaptively.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": Self.maxTokens,
            "messages": [["role": "user", "content": prompt]],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response, data)

        let rawBody = String(data: data, encoding: .utf8) ?? "(non-text response)"
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw AnthropicError.malformedResponse(rawBody)
        }

        // A safety decline is a successful HTTP 200 with an empty or partial
        // body, so it has to be checked before reading the content blocks.
        if json["stop_reason"] as? String == "refusal" {
            throw AnthropicError.refused(rawBody)
        }

        // Only the text blocks: Sonnet 5 and Opus 5 think adaptively by
        // default and prepend a `thinking` block (empty-texted, since
        // `display` defaults to omitted), which must not land in the notes.
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()

        guard !text.isEmpty else {
            // Thinking shares the max_tokens budget on the thinking models, so
            // a long enough meeting can exhaust it before any notes are
            // written. That's a distinct failure from a malformed payload.
            if json["stop_reason"] as? String == "max_tokens" {
                throw AnthropicError.truncated(rawBody)
            }
            throw AnthropicError.malformedResponse(rawBody)
        }
        return text
    }

    private static func checkStatus(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AnthropicError.malformedResponse("No HTTP response received.") }
        guard (200..<300).contains(http.statusCode) else {
            var message = String(data: data, encoding: .utf8) ?? "unknown error"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let errorMessage = error["message"] as? String {
                message = errorMessage
            }
            throw AnthropicError.http(http.statusCode, message)
        }
    }
}
