import Foundation
import Security

enum GoogleCalendarKeychain {
    static let service = "com.dosa.meetingnotes.google-calendar"
    static let accessTokenAccount = "accessToken"
    static let refreshTokenAccount = "refreshToken"
    static let expiryAccount = "tokenExpiry"
    // The OAuth client itself, when the user supplied one in Settings. Kept in
    // the same keychain as the tokens so it survives the app bundle being
    // replaced by an update — which is the whole point, since released builds
    // ship without a client baked into Info.plist.
    static let clientIDAccount = "clientID"
    static let clientSecretAccount = "clientSecret"

    static func set(_ value: String, account: String) {
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
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
