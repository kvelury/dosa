import Foundation
import AppKit
import CryptoKit

/// Google OAuth 2.0 for a desktop client: browser consent, PKCE, loopback redirect,
/// refresh tokens, and best-effort revocation on disconnect.
final class GoogleCalendarAuth {
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let scopes = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly",
    ]

    private static let callbackPorts: [UInt16] = [53690, 53691, 53692, 53693]

    /// The OAuth client Dosa authorizes with. Supplied by the user in Settings —
    /// nothing is ever baked into the app bundle.
    struct Credentials: Equatable {
        let clientID: String
        let clientSecret: String?
    }

    enum AuthError: LocalizedError {
        case credentialsMissing
        case malformedClientJSON(String)
        case notConnected
        case browserFailed
        case callbackFailed(String)
        case tokenExchangeFailed(String)
        case noFreePort
        case cancelled

        var errorDescription: String? {
            switch self {
            case .credentialsMissing:
                return "No Google OAuth client is configured. Add one in Settings › Google Calendar."
            case .malformedClientJSON(let detail):
                return "That doesn’t look like a Google OAuth client file: \(detail)"
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

    /// The OAuth client to authorize with, as configured in Settings. Kept in the
    /// keychain rather than the app bundle so it survives an update replacing the
    /// bundle, and so no credentials ever have to live in the repo or in a
    /// published release.
    static var credentials: Credentials? {
        guard let clientID = GoogleCalendarKeychain.string(account: GoogleCalendarKeychain.clientIDAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty else { return nil }
        return Credentials(
            clientID: clientID,
            clientSecret: GoogleCalendarKeychain.string(account: GoogleCalendarKeychain.clientSecretAccount)
        )
    }

    var hasCredentials: Bool {
        Self.credentials != nil
    }

    // MARK: - Configuring the client

    /// Accepts the file Google Cloud Console hands you for a Desktop client —
    /// `{"installed": {…}}` — as well as the `{"web": {…}}` variant and a flat
    /// object with the two fields at the top level.
    static func parseClientJSON(_ data: Data) throws -> Credentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.malformedClientJSON("it isn’t valid JSON.")
        }
        let container = (root["installed"] as? [String: Any])
            ?? (root["web"] as? [String: Any])
            ?? root

        func field(_ key: String) -> String? {
            let value = (container[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty == false) ? value : nil
        }

        guard let clientID = field("client_id") else {
            throw AuthError.malformedClientJSON("no client_id field.")
        }
        // Placeholder values parse fine but would fail at the consent screen with
        // an opaque Google error, so reject them up front.
        guard !clientID.hasPrefix("YOUR_") else {
            throw AuthError.malformedClientJSON("it still has placeholder values.")
        }
        return Credentials(clientID: clientID, clientSecret: field("client_secret"))
    }

    /// Stores the client and drops any existing session: tokens minted by a
    /// different client are invalid, and keeping them would surface later as an
    /// opaque invalid_grant on the next refresh.
    static func saveCredentials(_ credentials: Credentials) {
        GoogleCalendarKeychain.set(credentials.clientID, account: GoogleCalendarKeychain.clientIDAccount)
        if let secret = credentials.clientSecret {
            GoogleCalendarKeychain.set(secret, account: GoogleCalendarKeychain.clientSecretAccount)
        } else {
            GoogleCalendarKeychain.delete(account: GoogleCalendarKeychain.clientSecretAccount)
        }
        GoogleCalendarKeychain.clearTokens()
    }

    /// Leaves Calendar unconfigured until another client is supplied.
    static func clearCredentials() {
        GoogleCalendarKeychain.clearClientCredentials()
        GoogleCalendarKeychain.clearTokens()
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
        guard let credentials = Self.credentials else { throw AuthError.credentialsMissing }
        let clientID = credentials.clientID

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
        if let secret = credentials.clientSecret {
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
              let credentials = Self.credentials else {
            throw AuthError.notConnected
        }
        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": credentials.clientID,
        ]
        if let secret = credentials.clientSecret {
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
}
