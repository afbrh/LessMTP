import Foundation

// A read-only, extension-safe stand-in for GoogleAuthService's session-restore +
// token-refresh logic. GoogleAuthService itself can't be reused here as-is — its
// ASWebAuthenticationPresentationContextProviding conformance references
// UIApplication.shared, which is unavailable under this target's
// APPLICATION_EXTENSION_API_ONLY restriction. This widget never signs in on its own
// (it can't present UI) — it only reads the session the main app already signed in
// with, from the Keychain access group they share, and refreshes it if it's stale.
enum WidgetAuth {
    private static let clientID = "575902569700-en5vd08bgjh9e17enalgrvr9t3jguulp.apps.googleusercontent.com"

    static func loadValidAccessToken() async -> String? {
        guard let saved = KeychainStore.load(), let accessToken = saved["accessToken"] else { return nil }
        let refreshToken = saved["refreshToken"]
        var expiresAt: Date?
        if let expiresAtString = saved["expiresAt"], let interval = Double(expiresAtString) {
            expiresAt = Date(timeIntervalSince1970: interval)
        }

        if let expiresAt, expiresAt > Date().addingTimeInterval(120) {
            return accessToken
        }
        guard let refreshToken else { return accessToken }
        guard let refreshed = await refresh(refreshToken: refreshToken) else { return accessToken }

        var dict = ["accessToken": refreshed.accessToken, "refreshToken": refreshToken]
        if let expiresAt = refreshed.expiresAt { dict["expiresAt"] = String(expiresAt.timeIntervalSince1970) }
        KeychainStore.save(dict)
        return refreshed.accessToken
    }

    private static func refresh(refreshToken: String) async -> (accessToken: String, expiresAt: Date?)? {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        req.httpBody = params
            .map { key, value in "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        let obj = JSONHelpers.parse(data)
        guard let newToken = obj.string("access_token") else { return nil }
        var expiresAt: Date?
        if let expiresIn = obj["expires_in"] as? Int ?? Int(obj.string("expires_in") ?? "") {
            expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        }
        return (newToken, expiresAt)
    }
}
