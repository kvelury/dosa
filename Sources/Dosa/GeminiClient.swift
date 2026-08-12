import Foundation

/// Errors that carry the raw API/server response alongside a friendly summary,
/// so error dialogs can show technical details on demand.
protocol DetailedError: Error {
    var errorDetail: String? { get }
}

/// Minimal client for the Gemini API (https://ai.google.dev/gemini-api).
/// Uses the Files API for audio upload (resumable protocol) and
/// `models/<model>:generateContent` for transcription and note generation.
struct GeminiClient {
    let apiKey: String
    let model: String

    private static let base = "https://generativelanguage.googleapis.com"

    enum GeminiError: LocalizedError, DetailedError {
        case http(Int, String)
        case malformedResponse(String)
        case fileProcessingFailed(String)

        var errorDescription: String? {
            switch self {
            case .http(let status, _):
                return "The Gemini API returned an error (HTTP \(status))."
            case .malformedResponse:
                return "Gemini returned an unexpected response."
            case .fileProcessingFailed:
                return "Gemini could not process the uploaded audio file."
            }
        }

        var errorDetail: String? {
            switch self {
            case .http(_, let body), .malformedResponse(let body), .fileProcessingFailed(let body):
                return body.isEmpty ? nil : String(body.prefix(4000))
            }
        }
    }

    func transcribe(audioURL: URL, prompt: String) async throws -> String {
        let fileURI = try await uploadFile(at: audioURL, mimeType: "audio/mp4")
        return try await generateContent(parts: [
            ["file_data": ["mime_type": "audio/mp4", "file_uri": fileURI]],
            ["text": prompt],
        ])
    }

    func generateText(prompt: String) async throws -> String {
        try await generateContent(parts: [["text": prompt]])
    }

    // MARK: - Internals

    /// Runs generateContent against the selected model, falling back through known-good
    /// models when Google returns a server error (5xx), a retired-model 404, or a
    /// quota 429 — e.g. gemini-3.6-flash currently 500s on all audio input.
    private func generateContent(parts: [[String: Any]]) async throws -> String {
        var chain = [model]
        for fallback in AppSettings.fallbackModels where !chain.contains(fallback) {
            chain.append(fallback)
        }

        var lastError: Error?
        for candidate in chain {
            do {
                return try await generateContent(parts: parts, model: candidate)
            } catch let error as GeminiError {
                guard case .http(let status, _) = error,
                      status >= 500 || status == 404 || status == 429 else {
                    throw error
                }
                lastError = error
            }
        }
        throw lastError ?? GeminiError.malformedResponse("all model fallbacks failed")
    }

    private func generateContent(parts: [[String: Any]], model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Self.base)/v1beta/models/\(model):generateContent?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["contents": [["parts": parts]]])

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response, data)

        let rawBody = String(data: data, encoding: .utf8) ?? "(non-text response)"
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let responseParts = content["parts"] as? [[String: Any]] else {
            throw GeminiError.malformedResponse(rawBody)
        }
        let text = responseParts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw GeminiError.malformedResponse(rawBody) }
        return text
    }

    private func uploadFile(at url: URL, mimeType: String) async throws -> String {
        let data = try Data(contentsOf: url)

        var start = URLRequest(url: URL(string: "\(Self.base)/upload/v1beta/files?key=\(apiKey)")!)
        start.httpMethod = "POST"
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("\(data.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": url.lastPathComponent]])

        let (startData, startResponse) = try await URLSession.shared.data(for: start)
        try Self.checkStatus(startResponse, startData)
        guard let http = startResponse as? HTTPURLResponse,
              let uploadURLString = http.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString) else {
            throw GeminiError.malformedResponse(
                "Upload start response missing X-Goog-Upload-URL header. Body: \(String(data: startData, encoding: .utf8) ?? "")"
            )
        }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.timeoutInterval = 600
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")

        let (uploadData, uploadResponse) = try await URLSession.shared.upload(for: upload, from: data)
        try Self.checkStatus(uploadResponse, uploadData)
        guard let json = try JSONSerialization.jsonObject(with: uploadData) as? [String: Any],
              let file = json["file"] as? [String: Any],
              let uri = file["uri"] as? String,
              let name = file["name"] as? String else {
            throw GeminiError.malformedResponse(String(data: uploadData, encoding: .utf8) ?? "(non-text upload response)")
        }

        var state = file["state"] as? String ?? "ACTIVE"
        var attempts = 0
        while state == "PROCESSING" {
            attempts += 1
            if attempts > 90 { throw GeminiError.fileProcessingFailed("File stayed in PROCESSING state for over 3 minutes.") }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let (pollData, pollResponse) = try await URLSession.shared.data(
                from: URL(string: "\(Self.base)/v1beta/\(name)?key=\(apiKey)")!
            )
            try Self.checkStatus(pollResponse, pollData)
            guard let pollJSON = try JSONSerialization.jsonObject(with: pollData) as? [String: Any] else {
                throw GeminiError.malformedResponse(String(data: pollData, encoding: .utf8) ?? "(non-text poll response)")
            }
            state = pollJSON["state"] as? String ?? "ACTIVE"
        }
        guard state != "FAILED" else { throw GeminiError.fileProcessingFailed("The Files API reported state FAILED for the uploaded audio.") }
        return uri
    }

    private static func checkStatus(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw GeminiError.malformedResponse("No HTTP response received.") }
        guard (200..<300).contains(http.statusCode) else {
            var message = String(data: data, encoding: .utf8) ?? "unknown error"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let errorMessage = error["message"] as? String {
                message = errorMessage
            }
            throw GeminiError.http(http.statusCode, message)
        }
    }
}
