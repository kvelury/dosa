import Foundation
import AppKit
import CryptoKit

/// OAuth 2.1 against Notion's hosted MCP server. Uses Dynamic Client Registration
/// (RFC 7591), so no pre-registered integration or embedded client secret is
/// needed: Dosa registers itself on the fly, bounces the user to Notion's consent
/// page in the browser, and catches the redirect on a localhost listener.
final class NotionAuth {
    static let mcpEndpoint = URL(string: "https://mcp.notion.com/mcp")!
    private static let callbackPorts: [UInt16] = [53682, 53683, 53684, 53685]

    enum AuthError: LocalizedError {
        case notConnected
        case discoveryFailed(String)
        case registrationFailed(String)
        case browserFailed
        case callbackFailed(String)
        case tokenExchangeFailed(String)
        case noFreePort
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Notion is not connected. Open Settings and connect your Notion account."
            case .discoveryFailed(let detail):
                return "Could not discover Notion's authorization service: \(detail)"
            case .registrationFailed(let detail):
                return "Could not register Dosa with Notion: \(detail)"
            case .browserFailed:
                return "Could not open the browser for Notion authorization."
            case .callbackFailed(let detail):
                return "Notion authorization failed: \(detail)"
            case .tokenExchangeFailed(let detail):
                return "Could not complete Notion sign-in: \(detail)"
            case .noFreePort:
                return "Could not start the local sign-in listener (ports busy). Quit other apps using ports 53682-53685 and try again."
            case .cancelled:
                return "Notion sign-in was cancelled."
            }
        }
    }

    private struct Endpoints {
        let authorization: URL
        let token: URL
        let registration: URL?
    }

    private var loopbackServer: LoopbackHTTPServer?

    // MARK: - Public state

    var isConnected: Bool {
        UserDefaults.standard.string(forKey: AppSettings.notionAccessTokenKey) != nil
    }

    func clear() {
        let defaults = UserDefaults.standard
        for key in [AppSettings.notionAccessTokenKey, AppSettings.notionRefreshTokenKey,
                    AppSettings.notionTokenExpiryKey, AppSettings.notionClientIdKey,
                    AppSettings.notionTokenEndpointKey, AppSettings.notionWorkspaceKey] {
            defaults.removeObject(forKey: key)
        }
    }

    func cancelAuthorization() {
        loopbackServer?.cancel(with: AuthError.cancelled)
        loopbackServer = nil
    }

    // MARK: - Authorization flow

    func authorize() async throws {
        let endpoints = try await discoverEndpoints()
        let clientId = try await registerClient(endpoints: endpoints)

        guard let (server, port) = LoopbackHTTPServer.startOnFirstFreePort(Self.callbackPorts) else {
            throw AuthError.noFreePort
        }
        loopbackServer = server
        defer {
            server.stop()
            loopbackServer = nil
        }

        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let state = UUID().uuidString
        let verifier = Self.base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))

        var components = URLComponents(url: endpoints.authorization, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: Self.mcpEndpoint.absoluteString),
        ]
        guard let authorizeURL = components.url, NSWorkspace.shared.open(authorizeURL) else {
            throw AuthError.browserFailed
        }

        let code = try await server.waitForCode(
            expectedState: state,
            successBody: "Dosa is connected to Notion. You can close this tab and return to the app. 🥞"
        )

        let tokenResponse = try await requestToken(
            endpoint: endpoints.token,
            body: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectURI,
                "client_id": clientId,
                "code_verifier": verifier,
                "resource": Self.mcpEndpoint.absoluteString,
            ]
        )
        store(tokenResponse: tokenResponse, tokenEndpoint: endpoints.token)
    }

    /// Returns a usable access token, refreshing first when it is missing-expiry-safe.
    func validAccessToken() async throws -> String {
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: AppSettings.notionAccessTokenKey) else {
            throw AuthError.notConnected
        }
        let expiry = defaults.double(forKey: AppSettings.notionTokenExpiryKey)
        if expiry > 0, Date(timeIntervalSince1970: expiry) < Date().addingTimeInterval(60) {
            return try await refreshAccessToken()
        }
        return token
    }

    @discardableResult
    func refreshAccessToken() async throws -> String {
        let defaults = UserDefaults.standard
        guard let refreshToken = defaults.string(forKey: AppSettings.notionRefreshTokenKey),
              let clientId = defaults.string(forKey: AppSettings.notionClientIdKey),
              let tokenEndpointString = defaults.string(forKey: AppSettings.notionTokenEndpointKey),
              let tokenEndpoint = URL(string: tokenEndpointString) else {
            throw AuthError.notConnected
        }
        let response = try await requestToken(
            endpoint: tokenEndpoint,
            body: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientId,
                "resource": Self.mcpEndpoint.absoluteString,
            ]
        )
        store(tokenResponse: response, tokenEndpoint: tokenEndpoint)
        guard let token = response["access_token"] as? String else {
            throw AuthError.tokenExchangeFailed("No access token in refresh response.")
        }
        return token
    }

    // MARK: - Discovery & registration

    private func discoverEndpoints() async throws -> Endpoints {
        var authServerBase: URL?
        for path in ["/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource"] {
            if let json = try? await getJSON(URL(string: "https://mcp.notion.com\(path)")!),
               let servers = json["authorization_servers"] as? [String],
               let first = servers.first, let url = URL(string: first) {
                authServerBase = url
                break
            }
        }
        let base = authServerBase ?? URL(string: "https://mcp.notion.com")!

        var metadata: [String: Any]?
        for path in ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"] {
            if let json = try? await getJSON(base.appendingPathComponent(path)) {
                metadata = json
                break
            }
        }
        guard let metadata,
              let authString = metadata["authorization_endpoint"] as? String,
              let tokenString = metadata["token_endpoint"] as? String,
              let authorization = URL(string: authString),
              let token = URL(string: tokenString) else {
            throw AuthError.discoveryFailed("missing authorization metadata")
        }
        let registration = (metadata["registration_endpoint"] as? String).flatMap(URL.init(string:))
        return Endpoints(authorization: authorization, token: token, registration: registration)
    }

    private func registerClient(endpoints: Endpoints) async throws -> String {
        if let existing = UserDefaults.standard.string(forKey: AppSettings.notionClientIdKey) {
            return existing
        }
        guard let registration = endpoints.registration else {
            throw AuthError.registrationFailed("the server does not support dynamic client registration")
        }
        var request = URLRequest(url: registration)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Dosa",
            "redirect_uris": Self.callbackPorts.map { "http://127.0.0.1:\($0)/callback" },
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientId = json["client_id"] as? String else {
            throw AuthError.registrationFailed(String(data: data, encoding: .utf8) ?? "unknown error")
        }
        UserDefaults.standard.set(clientId, forKey: AppSettings.notionClientIdKey)
        return clientId
    }

    // MARK: - Token plumbing

    private func requestToken(endpoint: URL, body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { key, value in
                let escaped = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
                return "\(key)=\(escaped)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "unknown error")
        }
        return json
    }

    private func store(tokenResponse: [String: Any], tokenEndpoint: URL) {
        let defaults = UserDefaults.standard
        if let accessToken = tokenResponse["access_token"] as? String {
            defaults.set(accessToken, forKey: AppSettings.notionAccessTokenKey)
        }
        if let refreshToken = tokenResponse["refresh_token"] as? String {
            defaults.set(refreshToken, forKey: AppSettings.notionRefreshTokenKey)
        }
        if let expiresIn = tokenResponse["expires_in"] as? Double {
            defaults.set(Date().timeIntervalSince1970 + expiresIn, forKey: AppSettings.notionTokenExpiryKey)
        } else {
            defaults.removeObject(forKey: AppSettings.notionTokenExpiryKey)
        }
        defaults.set(tokenEndpoint.absoluteString, forKey: AppSettings.notionTokenEndpointKey)
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.discoveryFailed(url.absoluteString)
        }
        return json
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
