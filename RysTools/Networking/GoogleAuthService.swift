import AuthenticationServices
import CryptoKit
import Foundation
import UIKit
import UserNotifications

// Google blocks OAuth inside a plain embedded web view (WKWebView) — the sign-in
// screen has to run through ASWebAuthenticationSession, a system-provided secure
// browser sheet, instead. This needs its OWN "iOS" OAuth client ID from Google Cloud
// Console — a Web client ID (what budget.html/email.html/cal.html use) is not valid
// here. See README in this project folder for exactly how to create it.
//
// Unlike the web app (which uses the implicit response_type=token flow), this uses
// Authorization Code + PKCE (response_type=code, code_challenge/code_verifier, then a
// POST to the token endpoint) — Google's "iOS" client type rejects the implicit flow
// outright with a generic "Access Blocked: Authorization Error" (400), which is what
// happened here first. PKCE needs no client secret either, so it's still a good fit
// for a public/native client with nothing server-side to hold one.
@MainActor
final class GoogleAuthService: NSObject, ObservableObject {
    static let shared = GoogleAuthService()

    // iOS OAuth client created in Google Cloud Console (Credentials → Create Credentials
    // → OAuth client ID → iOS) under bundle id com.afbrh.RysTools.
    static let clientID = "575902569700-en5vd08bgjh9e17enalgrvr9t3jguulp.apps.googleusercontent.com"
    static var redirectScheme: String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }

    // Broader than the web app's drive.file scope, deliberately: drive.file only ever
    // sees files THIS OAuth client created, so a brand-new iOS client couldn't see the
    // munny-data.json file the web app already created under its own (different) client.
    // Full "drive" access lets this app find and read/write that exact same file, so
    // budget/scratch data shows up here for real instead of starting from empty.
    static let scope = [
        "https://www.googleapis.com/auth/drive",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.events",
        // For resolving a sender's name in the mail list from Google's own Contacts —
        // both real saved contacts (.contacts.readonly) and Gmail's own auto-collected
        // "Other contacts" (.contacts.other.readonly, people you've emailed but never
        // explicitly saved) — matching whatever name Gmail itself already shows for
        // them, rather than a separate lookup against the device's own iOS Contacts.
        "https://www.googleapis.com/auth/contacts.readonly",
        "https://www.googleapis.com/auth/contacts.other.readonly",
    ].joined(separator: " ")

    @Published private(set) var accessToken: String?
    @Published private(set) var isSignedIn = false
    @Published private(set) var userEmail: String?
    @Published var lastError: String?

    private var session: ASWebAuthenticationSession?
    private var codeVerifier: String = ""
    private var refreshToken: String?
    private var expiresAt: Date?

    override init() {
        super.init()
        restoreSession()
    }

    /// Loads whatever was saved in the Keychain at launch — if the access token still
    /// has life left, use it as-is; if it's expired but there's a refresh token, use
    /// that to get a new one silently, with no UI and no sign-in prompt.
    private func restoreSession() {
        guard let saved = KeychainStore.load(), let token = saved["accessToken"] else { return }
        accessToken = token
        refreshToken = saved["refreshToken"]
        if let expiresAtString = saved["expiresAt"], let interval = Double(expiresAtString) {
            expiresAt = Date(timeIntervalSince1970: interval)
        }
        isSignedIn = true
        Task { await fetchUserEmail() }
        Task { await BadgeUpdater.refresh(auth: self) }
        if let expiresAt, expiresAt <= Date() {
            Task { await refreshAccessTokenIfNeeded() }
        }
    }

    private func persistSession() {
        guard let accessToken else {
            KeychainStore.clear()
            return
        }
        var dict = ["accessToken": accessToken]
        if let refreshToken { dict["refreshToken"] = refreshToken }
        if let expiresAt { dict["expiresAt"] = String(expiresAt.timeIntervalSince1970) }
        KeychainStore.save(dict)
    }

    /// Called before any API call that needs a fresh token — refreshes quietly if the
    /// current one is within 2 minutes of expiring (or already expired), otherwise
    /// does nothing. No-op if there's no refresh token (falls back to a 401 downstream,
    /// which for this app's scope means signing in again).
    func refreshAccessTokenIfNeeded() async {
        guard let refreshToken else { return }
        if let expiresAt, expiresAt > Date().addingTimeInterval(120) { return }

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params: [String: String] = [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        req.httpBody = params
            .map { key, value in "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return }
        let obj = JSONHelpers.parse(data)
        guard let newToken = obj.string("access_token") else {
            // Refresh token itself is no longer valid (revoked, expired from disuse) —
            // clear everything so the UI falls back to showing Sign In rather than
            // silently retrying a dead token forever.
            signOut()
            return
        }
        accessToken = newToken
        if let expiresIn = obj["expires_in"] as? Int ?? Int(obj.string("expires_in") ?? "") {
            expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        }
        persistSession()
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hashed = SHA256.hash(data: Data(verifier.utf8))
        return Data(hashed).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func signIn() {
        guard !Self.clientID.hasPrefix("YOUR_IOS_CLIENT_ID") else {
            lastError = "Add your iOS OAuth client ID to GoogleAuthService.swift first (see README)."
            return
        }
        codeVerifier = Self.randomURLSafeString(byteCount: 32)
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: "\(Self.redirectScheme):/oauth2redirect"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "prompt", value: "select_account"),
            // Without this, Google only issues a refresh_token on the very first
            // consent ever granted to this client — unreliable to depend on. With it,
            // sign-in keeps working across app launches instead of expiring in ~1hr.
            URLQueryItem(name: "access_type", value: "offline"),
        ]
        guard let authURL = comps.url else { return }

        // The completion handler's own closure type isn't main-actor-isolated, so every
        // touch of self (a @MainActor class) inside it has to hop over explicitly.
        let s = ASWebAuthenticationSession(url: authURL, callbackURLScheme: Self.redirectScheme) { [weak self] callbackURL, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    let nsError = error as NSError
                    // Code 1 is the user tapping Cancel — not a real error, don't show it.
                    if nsError.code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        self.lastError = error.localizedDescription
                    }
                    return
                }
                guard let callbackURL else { return }
                self.handleCallback(callbackURL)
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        s.start()
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
        expiresAt = nil
        isSignedIn = false
        userEmail = nil
        KeychainStore.clear()
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
    }

    private func handleCallback(_ url: URL) {
        // The authorization code comes back in the URL's QUERY string (?code=...),
        // unlike the implicit flow's fragment (#access_token=...) the web app uses.
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = query.first(where: { $0.name == "code" })?.value else {
            lastError = query.first(where: { $0.name == "error" })?.value ?? "Sign-in didn't return an authorization code."
            return
        }
        Task { await exchangeCodeForToken(code) }
    }

    private func exchangeCodeForToken(_ code: String) async {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params: [String: String] = [
            "code": code,
            "client_id": Self.clientID,
            "redirect_uri": "\(Self.redirectScheme):/oauth2redirect",
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
        ]
        req.httpBody = params
            .map { key, value in "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = JSONHelpers.parse(data)
            guard let token = obj.string("access_token") else {
                lastError = obj.string("error_description") ?? obj.string("error") ?? "Token exchange failed."
                return
            }
            accessToken = token
            if let newRefreshToken = obj.string("refresh_token") { refreshToken = newRefreshToken }
            if let expiresIn = obj["expires_in"] as? Int ?? Int(obj.string("expires_in") ?? "") {
                expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
            }
            isSignedIn = true
            lastError = nil
            persistSession()
            await fetchUserEmail()
            await BadgeUpdater.refresh(auth: self)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func fetchUserEmail() async {
        guard let token = accessToken else { return }
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return }
        let obj = JSONHelpers.parse(data)
        userEmail = obj.string("email")
    }
}

extension GoogleAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                for window in windowScene.windows where window.isKeyWindow {
                    return window
                }
            }
        }
        return ASPresentationAnchor()
    }
}
