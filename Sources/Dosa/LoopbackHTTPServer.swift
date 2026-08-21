import Foundation
import Network

/// Minimal one-shot HTTP listener that catches an OAuth redirect on localhost.
final class LoopbackHTTPServer {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var resumeOnce: ((Result<String, Error>) -> Void)?
    private var expectedState = ""
    private var successBody = "You can close this tab and return to Dosa."

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func startOnFirstFreePort(_ ports: [UInt16]) -> (LoopbackHTTPServer, UInt16)? {
        for port in ports {
            guard let nwPort = NWEndpoint.Port(rawValue: port),
                  let listener = try? NWListener(using: .tcp, on: nwPort) else { continue }
            let server = LoopbackHTTPServer(listener: listener)
            return (server, port)
        }
        return nil
    }

    func waitForCode(expectedState: String, successBody: String) async throws -> String {
        self.expectedState = expectedState
        self.successBody = successBody
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            resumeOnce = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receiveRequest(on: connection)
            }
            listener.start(queue: .main)
        }
    }

    func cancel(with error: Error) {
        resumeOnce?(.failure(error))
        stop()
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func receiveRequest(on connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data {
                buffer.append(data)
            }
            let text = String(decoding: buffer, as: UTF8.self)
            if let requestLineEnd = text.range(of: "\r\n") {
                self.handleRequestLine(String(text[..<requestLineEnd.lowerBound]), connection: connection)
            } else if error == nil, !isComplete, buffer.count < 65536 {
                self.receiveRequest(on: connection, buffered: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func handleRequestLine(_ line: String, connection: NWConnection) {
        let parts = line.components(separatedBy: " ")
        guard parts.count >= 2 else {
            respond(connection, status: "400 Bad Request", body: "Bad request")
            return
        }
        let path = parts[1]
        guard path.hasPrefix("/callback"),
              let components = URLComponents(string: "http://127.0.0.1\(path)") else {
            respond(connection, status: "404 Not Found", body: "Not found")
            return
        }
        let items = components.queryItems ?? []
        let code = items.first { $0.name == "code" }?.value
        let state = items.first { $0.name == "state" }?.value
        let oauthError = items.first { $0.name == "error" }?.value

        if let oauthError {
            respond(connection, status: "200 OK", body: "Authorization failed: \(oauthError). You can close this tab.")
            resumeOnce?(.failure(LoopbackHTTPServerError.callbackFailed(oauthError)))
        } else if let code, state == expectedState {
            respond(connection, status: "200 OK", body: successBody)
            resumeOnce?(.success(code))
        } else {
            respond(connection, status: "400 Bad Request", body: "Authorization response was invalid. Return to Dosa and try again.")
            resumeOnce?(.failure(LoopbackHTTPServerError.callbackFailed("missing or mismatched authorization code")))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = """
        <html><head><meta charset="utf-8"><title>Dosa</title></head>\
        <body style="font-family: -apple-system, sans-serif; text-align: center; padding-top: 80px;">\
        <h2>\(body)</h2></body></html>
        """
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum LoopbackHTTPServerError: LocalizedError {
    case callbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .callbackFailed(let detail):
            return "Authorization failed: \(detail)"
        }
    }
}
