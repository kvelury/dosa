import Foundation
import AppKit
import CryptoKit

/// Google OAuth 2.0 for a desktop client: browser consent, PKCE, loopback redirect,
/// refresh tokens, and best-effort revocation on disconnect.
final class GoogleCalendarAuth {
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let clientIDInfoKey = "DOSAGoogleCalendarClientID"
    static let clientSecretInfoKey = "DOSAGoogleCalendarClientSecret"
    static let scopes = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly",
    ]

    private static let callbackPorts: [UInt16] = [53690, 53691, 53692, 53693]

    enum AuthError: LocalizedError {
        case credentialsMissing
        case notConnected
        case browserFailed
        case callbackFailed(String)
        case tokenExchangeFailed(String)
        case noFreePort
        case cancelled

        var errorDescription: String? {
            switch self {
            case .credentialsMissing:
                return "This build of Dosa doesn’t include Google Calendar credentials. Add Resources/GoogleCalendarOAuth.json and rebuild."
            case .notConnected:
                return "Google Calendar is not connected. Open Settings and connect your Google account."
            case .browserFailed:
                return "Could not open the browser for Google authorization."
            case .callbackFailed(let detail):
                return "Google authorization failed: \(detail)"
            case .tokenExchangeFailed(let detail):
                return "Could not complete Google sign-in: \(detail)"
            case .noFreePort:
                return "Could not start the local sign-in listener (ports busy). Quit other apps using ports 53690-53693 and try again."
            case .cancelled:
                return "Google sign-in was cancelled."
            }
        }
    }

    private var loopbackServer: LoopbackHTTPServer?

    static var clientID: String? {
        string(fromInfo: clientIDInfoKey)
    }

    static var clientSecret: String? {
        string(fromInfo: clientSecretInfoKey)
    }

    var hasCredentials: Bool {
        Self.clientID != nil
    }

    var isConnected: Bool {
        GoogleCalendarKeychain.string(account: GoogleCalendarKeychain.accessTokenAccount) != nil
            || GoogleCalendarKeychain.string(account: GoogleCalendarKeychain.refreshTokenAccount) != nil
    }

    func clear() {
        if let token = GoogleCalendarKeychain.string(account: GoogleCalendarKeychain.accessTokenAccount)
            ?? GoogleCalendarKeychain.string(account: GoogleCalendarKeychain.refreshTokenAccount) {
            Task { await Self.revoke(token: token) }
        }
        GoogleCalendarKeychain.clearTokens()
    }

    func cancelAuthorization() {
        loopbackServer?.cancel(with: AuthError.cancelled)
        loopbackServer = nil
    }

    func authorize() async throws {
        guard let clientID = Self.clientID else { throw AuthError.credentialsMissing }

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
        let verifier = NotionAuth.base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let challenge = NotionAuth.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))

        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizeURL = components.url, NSWorkspace.shared.open(authorizeURL) else {
            throw AuthError.browserFailed
        }

        let code: String
        do {
            code = try await server.waitForCode(
                expectedState: state,
                successBody: "Dosa is connected to Google Calendar. You can close this tab and return to the app. 🥞"
            )
        } catch let error as LoopbackHTTPServerError {
            if case .callbackFailed(let detail) = error {
                throw AuthError.callbackFailed(detail)
            }
            throw error
        }

        var body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ]
        if let secret = Self.clientSecret {
            body["client_secret"] = secret
        }
        let tokenResponse = try await requestToken(body: body)
        store(tokenResponse: tokenResponse)
    }

    func validAccessToken() async throws -> String {
        guard let token = GoogleCalendarKeychain.string(account: GoogleCalendarKeychain.accessTokenAccount) else {
            throw AuthError.notConnected
        }
        let expiry = expiryDate()
        if OAuthTokenTiming.needsRefresh(expiry: expiry) {
            return try await refreshAccessToken()
        }
        return token
    }

    @discardableResult
    func refreshAccessToken() async throws -> String {
        guard let refreshToken = GoogleCalendarKeychain.string(account: GoogleCalendarKeychain.refreshTokenAccount),
              let clientID = Self.clientID else {
            throw AuthError.notConnected
        }
        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if let secret = Self.clientSecret {
            body["client_secret"] = secret
        }
        let response = try await requestToken(body: body)
        store(tokenResponse: response, preservingRefreshToken: refreshToken)
        guard let token = response["access_token"] as? String else {
            throw AuthError.tokenExchangeFailed("No access token in refresh response.")
        }
        return token
    }

    private func expiryDate() -> Date? {
        guard let raw = GoogleCalendarKeychain.string(account: GoogleCalendarKeychain.expiryAccount),
              let interval = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    private func store(tokenResponse: [String: Any], preservingRefreshToken: String? = nil) {
        if let accessToken = tokenResponse["access_token"] as? String {
            GoogleCalendarKeychain.set(accessToken, account: GoogleCalendarKeychain.accessTokenAccount)
        }
        if let refreshToken = tokenResponse["refresh_token"] as? String {
            GoogleCalendarKeychain.set(refreshToken, account: GoogleCalendarKeychain.refreshTokenAccount)
        } else if let preservingRefreshToken {
            GoogleCalendarKeychain.set(preservingRefreshToken, account: GoogleCalendarKeychain.refreshTokenAccount)
        }
        if let expiresIn = tokenResponse["expires_in"] as? NSNumber {
            GoogleCalendarKeychain.set(
                String(Date().timeIntervalSince1970 + expiresIn.doubleValue),
                account: GoogleCalendarKeychain.expiryAccount
            )
        }
    }

    private func requestToken(body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "unknown error")
        }
        return json
    }

    private static func revoke(token: String) async {
        var request = URLRequest(url: revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token)".data(using: .utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func formBody(_ body: [String: String]) -> Data? {
        body.map { key, value in
            let escaped = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
            return "\(key)=\(escaped)"
        }
        .joined(separator: "&")
        .data(using: .utf8)
    }

    private static func string(fromInfo key: String) -> String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }
}
