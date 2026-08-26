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

    /// A stored string, or nil when it is absent or blank. Blank matters: the
    /// paste sheet can leave an empty string behind, and an empty client ID has
    /// to read as "no client configured" rather than as a configured empty one.
    private static func stored(_ key: String) -> String? {
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    /// The configured client's ID. Read constantly — SwiftUI re-evaluates it on
    /// every render of the Settings section.
    static var clientID: String? {
        stored(AppSettings.googleCalendarClientIDKey)
    }

    /// The full client, secret included.
    static var credentials: Credentials? {
        guard let clientID else { return nil }
        return Credentials(
            clientID: clientID,
            clientSecret: stored(AppSettings.googleCalendarClientSecretKey)
        )
    }

    var hasCredentials: Bool {
        Self.clientID != nil
    }

    /// Wipes the session but deliberately leaves the client credentials alone:
    /// disconnecting an account should not un-configure the OAuth client.
    private static func clearTokens() {
        let defaults = UserDefaults.standard
        for key in [AppSettings.googleCalendarAccessTokenKey,
                    AppSettings.googleCalendarRefreshTokenKey,
                    AppSettings.googleCalendarExpiryKey] {
            defaults.removeObject(forKey: key)
        }
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
        let defaults = UserDefaults.standard
        defaults.set(credentials.clientID, forKey: AppSettings.googleCalendarClientIDKey)
        if let secret = credentials.clientSecret {
            defaults.set(secret, forKey: AppSettings.googleCalendarClientSecretKey)
        } else {
            defaults.removeObject(forKey: AppSettings.googleCalendarClientSecretKey)
        }
        clearTokens()
    }

    /// Leaves Calendar unconfigured until another client is supplied.
    static func clearCredentials() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AppSettings.googleCalendarClientIDKey)
        defaults.removeObject(forKey: AppSettings.googleCalendarClientSecretKey)
        clearTokens()
    }

    var isConnected: Bool {
        Self.stored(AppSettings.googleCalendarAccessTokenKey) != nil
            || Self.stored(AppSettings.googleCalendarRefreshTokenKey) != nil
    }

    func clear() {
        if let token = Self.stored(AppSettings.googleCalendarAccessTokenKey)
            ?? Self.stored(AppSettings.googleCalendarRefreshTokenKey) {
            Task { await Self.revoke(token: token) }
        }
        Self.clearTokens()
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
        guard let token = Self.stored(AppSettings.googleCalendarAccessTokenKey) else {
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
        guard let refreshToken = Self.stored(AppSettings.googleCalendarRefreshTokenKey),
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

    /// `object(forKey:)` rather than `double(forKey:)`: the latter turns an absent
    /// value into 0, which would read as an expiry in 1970 and force a refresh on
    /// every call. A missing expiry has to stay nil — `OAuthTokenTiming` treats
    /// that as "not known to be expired".
    private func expiryDate() -> Date? {
        guard let interval = UserDefaults.standard.object(forKey: AppSettings.googleCalendarExpiryKey) as? Double
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    private func store(tokenResponse: [String: Any], preservingRefreshToken: String? = nil) {
        let defaults = UserDefaults.standard
        if let accessToken = tokenResponse["access_token"] as? String {
            defaults.set(accessToken, forKey: AppSettings.googleCalendarAccessTokenKey)
        }
        if let refreshToken = tokenResponse["refresh_token"] as? String {
            defaults.set(refreshToken, forKey: AppSettings.googleCalendarRefreshTokenKey)
        } else if let preservingRefreshToken {
            defaults.set(preservingRefreshToken, forKey: AppSettings.googleCalendarRefreshTokenKey)
        }
        if let expiresIn = tokenResponse["expires_in"] as? NSNumber {
            defaults.set(Date().timeIntervalSince1970 + expiresIn.doubleValue,
                         forKey: AppSettings.googleCalendarExpiryKey)
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
