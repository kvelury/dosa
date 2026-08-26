import Foundation
import Security

/// Dosa no longer keeps anything in the keychain. Credentials live in
/// UserDefaults alongside the Notion tokens and the provider API keys — see
/// `AppSettings.googleCalendarClientSecretKey` and friends.
///
/// The keychain had to go because Dosa is ad-hoc signed: a generic-password
/// item's ACL is bound to the creating code's signature, an ad-hoc signature's
/// designated requirement is its cdhash, and every `./build.sh` produces a new
/// one. "Always Allow" was therefore void by the next build, and each launch
/// cost a fresh round of access prompts.
///
/// This clears out what older builds left behind. It deliberately never *reads*
/// an item: a read has to decrypt, which is what raises the prompt, while a
/// delete does not. Runs once ever, and sets its flag before deleting so even a
/// denied dialog cannot come back on a later launch.
///
/// Safe to delete this file outright a release or two from now.
enum GoogleCalendarKeychainPurge {
    private static let service = "com.dosa.meetingnotes.google-calendar"
    /// `clientID` was moved to UserDefaults by an earlier build's migration, but
    /// an install that never ran it still has the item.
    private static let accounts = ["accessToken", "refreshToken", "tokenExpiry", "clientSecret", "clientID"]

    static func runOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppSettings.googleCalendarKeychainPurgedKey) else { return }
        defaults.set(true, forKey: AppSettings.googleCalendarKeychainPurgedKey)
        for account in accounts {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }
    }
}
