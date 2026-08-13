import Foundation

/// Minimal client for the DeepSeek API (https://api.deepseek.com), which is
/// OpenAI-compatible. Text-only: DeepSeek has no audio input, so transcription
/// always goes through Gemini regardless of the selected provider.
struct DeepSeekClient {
    let apiKey: String
    let model: String

    private static let base = "https://api.deepseek.com"

    enum DeepSeekError: LocalizedError, DetailedError {
        case http(Int, String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .http(let status, _):
                return "The DeepSeek API returned an error (HTTP \(status))."
            case .malformedResponse:
                return "DeepSeek returned an unexpected response."
            }
        }

        var errorDetail: String? {
            switch self {
            case .http(_, let body), .malformedResponse(let body):
                return body.isEmpty ? nil : String(body.prefix(4000))
            }
        }
    }

    func generateText(prompt: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Self.base)/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response, data)

        let rawBody = String(data: data, encoding: .utf8) ?? "(non-text response)"
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty else {
            throw DeepSeekError.malformedResponse(rawBody)
        }
        return text
    }

    private static func checkStatus(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw DeepSeekError.malformedResponse("No HTTP response received.") }
        guard (200..<300).contains(http.statusCode) else {
            var message = String(data: data, encoding: .utf8) ?? "unknown error"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let errorMessage = error["message"] as? String {
                message = errorMessage
            }
            throw DeepSeekError.http(http.statusCode, message)
        }
    }
}
