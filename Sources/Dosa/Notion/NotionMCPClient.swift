import Foundation

/// Minimal MCP client for Notion's hosted server (Streamable HTTP transport).
/// Speaks just enough of the protocol for deterministic tool calls:
/// initialize → notifications/initialized → tools/call.
final class NotionMCPClient {
    enum ClientError: LocalizedError, DetailedError {
        case unauthorized
        case http(Int, String)
        case rpc(String)
        case tool(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "Notion rejected the connection. Reconnect your account in Settings."
            case .http(let status, _):
                return "The Notion request failed (HTTP \(status))."
            case .rpc:
                return "Notion reported a protocol error."
            case .tool:
                return "Notion could not complete the request."
            case .malformed:
                return "Notion returned an unexpected response."
            }
        }

        var errorDetail: String? {
            switch self {
            case .unauthorized:
                return nil
            case .http(_, let body), .rpc(let body), .tool(let body), .malformed(let body):
                return body.isEmpty ? nil : String(body.prefix(4000))
            }
        }
    }

    private let endpoint = NotionAuth.mcpEndpoint
    private var sessionId: String?
    private var negotiatedVersion: String?
    private var requestCounter = 0

    func reset() {
        sessionId = nil
        negotiatedVersion = nil
    }

    func callTool(name: String, arguments: [String: Any], accessToken: String) async throws -> String {
        if negotiatedVersion == nil {
            try await initializeSession(accessToken: accessToken)
        }
        do {
            return try await performToolCall(name: name, arguments: arguments, accessToken: accessToken)
        } catch ClientError.http(let status, _) where status == 404 || status == 400 {
            // Session likely expired; establish a fresh one and retry once.
            reset()
            try await initializeSession(accessToken: accessToken)
            return try await performToolCall(name: name, arguments: arguments, accessToken: accessToken)
        }
    }

    // MARK: - Internals

    private func performToolCall(name: String, arguments: [String: Any], accessToken: String) async throws -> String {
        let (result, _) = try await sendRequest(
            method: "tools/call",
            params: ["name": name, "arguments": arguments],
            accessToken: accessToken
        )
        guard let content = result["content"] as? [[String: Any]] else {
            throw ClientError.malformed("tool result had no content")
        }
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        if (result["isError"] as? Bool) == true {
            throw ClientError.tool(text.isEmpty ? "unknown tool error" : text)
        }
        return text
    }

    private func initializeSession(accessToken: String) async throws {
        let (result, response) = try await sendRequest(
            method: "initialize",
            params: [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": [
                    "name": "Dosa",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3",
                ],
            ],
            accessToken: accessToken,
            isInitialize: true
        )
        negotiatedVersion = result["protocolVersion"] as? String ?? "2025-06-18"
        sessionId = response.value(forHTTPHeaderField: "Mcp-Session-Id")
        try await sendNotification(method: "notifications/initialized", accessToken: accessToken)
    }

    private func sendRequest(
        method: String,
        params: [String: Any],
        accessToken: String,
        isInitialize: Bool = false
    ) async throws -> ([String: Any], HTTPURLResponse) {
        requestCounter += 1
        let requestId = requestCounter
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": method,
            "params": params,
        ]
        let (data, http) = try await post(payload: payload, accessToken: accessToken, isInitialize: isInitialize)

        let message = try parseMessage(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "", requestId: requestId)
        if let errorObject = message["error"] as? [String: Any] {
            throw ClientError.rpc(errorObject["message"] as? String ?? "unknown error")
        }
        guard let result = message["result"] as? [String: Any] else {
            throw ClientError.malformed("response had no result")
        }
        return (result, http)
    }

    private func sendNotification(method: String, accessToken: String) async throws {
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": method]
        _ = try? await post(payload: payload, accessToken: accessToken)
    }

    private func post(
        payload: [String: Any],
        accessToken: String,
        isInitialize: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if !isInitialize, let negotiatedVersion {
            request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.malformed("no HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ClientError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return (data, http)
    }

    private func parseMessage(data: Data, contentType: String, requestId: Int) throws -> [String: Any] {
        if contentType.contains("text/event-stream") {
            return try parseSSE(String(decoding: data, as: UTF8.self), requestId: requestId)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.malformed("body was not JSON")
        }
        return json
    }

    /// Extracts the JSON-RPC response matching `requestId` from an SSE body,
    /// skipping unrelated server notifications/log events on the stream.
    private func parseSSE(_ body: String, requestId: Int) throws -> [String: Any] {
        var dataBuffer = ""

        func finishEvent() -> [String: Any]? {
            guard !dataBuffer.isEmpty else { return nil }
            defer { dataBuffer = "" }
            guard let object = try? JSONSerialization.jsonObject(with: Data(dataBuffer.utf8)) as? [String: Any] else {
                return nil
            }
            if let id = object["id"] as? Int, id == requestId {
                return object
            }
            return nil
        }

        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.hasPrefix("data:") {
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                dataBuffer += dataBuffer.isEmpty ? payload : "\n" + payload
            } else if line.isEmpty {
                if let message = finishEvent() {
                    return message
                }
            }
        }
        if let message = finishEvent() {
            return message
        }
        throw ClientError.malformed("no matching response on event stream")
    }
}
