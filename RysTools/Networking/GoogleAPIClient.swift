import Foundation

enum APIError: Error, LocalizedError {
    case notSignedIn
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in."
        case .http(let code, let body): return "HTTP \(code): \(body)"
        }
    }
}

// Thin shared wrapper around URLSession — every call here mirrors a fetch() call in
// the web app's GoogleDriveSync module, just from Swift instead of JS. @MainActor
// because GoogleAuthService (where accessToken lives) is main-actor-isolated.
@MainActor
struct GoogleAPIClient {
    let auth: GoogleAuthService

    private func authorizedRequest(_ url: URL, method: String = "GET") async throws -> URLRequest {
        await auth.refreshAccessTokenIfNeeded()
        guard let token = auth.accessToken else { throw APIError.notSignedIn }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    func get(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw APIError.http(0, "bad url") }
        let req = try await authorizedRequest(url)
        return try await sendWithRetry(req)
    }

    func getJSON(_ urlString: String) async throws -> JSONObject {
        JSONHelpers.parse(try await get(urlString))
    }

    func send(_ urlString: String, method: String, body: Data?, contentType: String = "application/json") async throws -> Data {
        guard let url = URL(string: urlString) else { throw APIError.http(0, "bad url") }
        var req = try await authorizedRequest(url, method: method)
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await sendWithRetry(req)
    }

    // A request in flight when the app backgrounds, or when SwiftUI's own
    // .refreshable/.task cancels its action Task (it does this readily — e.g. once the
    // pull-to-refresh spinner's own animation finishes, sometimes before the network
    // call it kicked off actually completes), comes back as URLError.cancelled. Retrying
    // with a plain `await` doesn't help if the *enclosing* Task is the one that's
    // cancelled, not just this one URLSessionTask — every subsequent await in that same
    // Task fails the same way immediately. Task { ... } starts a genuinely new,
    // independent task tree, so it isn't cancelled just because the caller's was.
    private func sendWithRetry(_ req: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            try checkStatus(response, data)
            return data
        } catch let error as URLError where error.code == .cancelled {
            return try await Task { @MainActor in
                let (data, response) = try await URLSession.shared.data(for: req)
                try checkStatus(response, data)
                return data
            }.value
        }
    }

    private func checkStatus(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
