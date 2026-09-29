import Foundation
import Security

// Minimal Keychain wrapper for persisting the signed-in session across launches — the
// access token is short-lived and sensitive, so this belongs in the Keychain, not
// UserDefaults. One entry, holding accessToken/refreshToken/expiresAt as JSON.
//
// Shared with the CalendarWidgetExtension target via a Keychain Sharing access group
// (see both targets' .entitlements files) — the widget runs in its own process, so it
// needs this same access group to read the session the main app signed in with. This
// file is deliberately kept dependency-free (no UIApplication/ASWebAuthenticationSession)
// so it's safe to compile into an APPLICATION_EXTENSION_API_ONLY target.
enum KeychainStore {
    private static let service = "com.afbrh.RysTools.google-session"
    private static let accessGroup = "8G7VVSU6R2.com.afbrh.RysTools.shared"

    static func save(_ dict: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load() -> [String: String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
