import Foundation
import Security

enum GoogleCalendarKeychain {
    static let service = "com.dosa.meetingnotes.google-calendar"
    static let accessTokenAccount = "accessToken"
    static let refreshTokenAccount = "refreshToken"
    static let expiryAccount = "tokenExpiry"
    /// The client secret the user supplied in Settings. Lives here rather than in
    /// the app bundle so it survives an update replacing the bundle, and so no
    /// secret has to sit in the repo or in a public release. (The client ID is
    /// not a secret and lives in UserDefaults — see `GoogleCalendarAuth.clientID`.
    /// `clientIDAccount` remains only so older installs can be migrated off it.)
    static let clientSecretAccount = "clientSecret"
    static let clientIDAccount = "clientID"

    // Dosa is ad-hoc signed, so every rebuild changes the code signature that a
    // keychain item's ACL was bound to and macOS re-prompts for access. Reads
    // therefore have to be rare: this write-through cache makes each account cost
    // at most one prompt per launch, no matter how often callers ask. This
    // process is the only writer, so a cached value cannot go stale underneath us.
    // A `nil` result is cached too — including one caused by the user denying the
    // prompt — so a denial does not turn into a prompt loop.
    private static let cacheLock = NSLock()
    private static var cache: [String: String?] = [:]

    private static func cached(_ account: String) -> String?? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[account]
    }

    private static func store(_ value: String?, for account: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[account] = value
    }

    static func set(_ value: String, account: String) {
        defer { store(value, for: account) }
        delete(account: account)
        let payload = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: payload,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func string(account: String) -> String? {
        if let hit = cached(account) { return hit }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value: String?
        if status == errSecSuccess, let data = result as? Data {
            value = String(data: data, encoding: .utf8)
        } else {
            value = nil
        }
        store(value, for: account)
        return value
    }

    static func delete(account: String) {
        defer { store(nil, for: account) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Wipes the session but deliberately leaves the client credentials alone:
    /// disconnecting an account should not un-configure the OAuth client.
    static func clearTokens() {
        delete(account: accessTokenAccount)
        delete(account: refreshTokenAccount)
        delete(account: expiryAccount)
    }

    static func clearClientCredentials() {
        delete(account: clientIDAccount)
        delete(account: clientSecretAccount)
    }
}
