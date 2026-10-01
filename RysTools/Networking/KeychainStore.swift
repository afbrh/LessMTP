import Foundation
import Security

// Minimal Keychain wrapper for persisting the signed-in session across launches — the
// access token is short-lived and sensitive, so this belongs in the Keychain, not
// UserDefaults. One entry, holding accessToken/refreshToken/expiresAt as JSON.
//
// Still scoped to a named Keychain Sharing access group (see RysTools.entitlements) —
// a leftover from when this was also shared with the now-removed CalendarWidgetExtension
// target, left as-is rather than migrated to avoid silently signing out anyone with an
// existing session stored under it.
enum KeychainStore {
    private static let service = "com.afbrh.LessMTP.google-session"
    private static let accessGroup = "8G7VVSU6R2.com.afbrh.LessMTP.shared"

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
