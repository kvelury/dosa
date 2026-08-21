import Foundation
import Security

enum GoogleCalendarKeychain {
    static let service = "com.dosa.meetingnotes.google-calendar"
    static let accessTokenAccount = "accessToken"
    static let refreshTokenAccount = "refreshToken"
    static let expiryAccount = "tokenExpiry"

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

    static func clearTokens() {
        delete(account: accessTokenAccount)
        delete(account: refreshTokenAccount)
        delete(account: expiryAccount)
    }
}
