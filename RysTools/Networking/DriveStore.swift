import Foundation

// Mirrors budget.html/email.html/cal.html/scratch.html's shared GoogleDriveSync +
// withToolsWrapper/extractOwnToolData/mergeAndSave pattern: ONE Drive file
// ("munny-data.json"), keyed by tools.<name>, shared by every tool page — and now
// this native app too, so it reads/writes the exact same data as the web tools.
@MainActor
final class DriveStore: ObservableObject {
    static let shared = DriveStore(auth: .shared)

    private let fileName = "munny-data.json"
    private var cachedFileId: String?
    private let auth: GoogleAuthService
    private var api: GoogleAPIClient { GoogleAPIClient(auth: auth) }

    init(auth: GoogleAuthService) {
        self.auth = auth
    }

    private func findFileId() async throws -> String? {
        if let cachedFileId { return cachedFileId }
        let q = "name='\(fileName)' and trashed=false"
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let url = "https://www.googleapis.com/drive/v3/files?q=\(encoded)&spaces=drive&fields=files(id,name)"
        let obj = try await api.getJSON(url)
        guard let files = obj["files"] as? [JSONObject], let first = files.first, let id = first["id"] as? String else {
            return nil
        }
        cachedFileId = id
        return id
    }

    /// Returns the tools.<name> wrapper, or an empty object for a brand-new file — same
    /// null-safety as the web app's withToolsWrapper.
    func loadTools() async throws -> JSONObject {
        guard let fileId = try await findFileId() else { return [:] }
        let raw = try await api.getJSON("https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media")
        if let tools = raw["tools"] as? JSONObject { return tools }
        // Pre-multi-tool file: the whole thing is budget's own data.
        return raw.isEmpty ? [:] : ["budget": raw]
    }

    func save(tool: String, data: JSONObject) async throws {
        var tools = try await loadTools()
        tools[tool] = data
        let payload: JSONObject = ["tools": tools]
        let bodyData = JSONHelpers.serialize(payload)

        if let fileId = try await findFileId() {
            let uploadURL = "https://www.googleapis.com/upload/drive/v3/files/\(fileId)?uploadType=media"
            _ = try await api.send(uploadURL, method: "PATCH", body: bodyData)
        } else {
            // multipart create: metadata part (name) + media part (the JSON itself).
            let boundary = "rystools-\(UUID().uuidString)"
            var body = Data()
            func appendString(_ s: String) { body.append(s.data(using: .utf8)!) }
            appendString("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
            appendString("{\"name\":\"\(fileName)\"}\r\n")
            appendString("--\(boundary)\r\nContent-Type: application/json\r\n\r\n")
            body.append(bodyData)
            appendString("\r\n--\(boundary)--")
            let createURL = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart"
            let responseData = try await api.send(createURL, method: "POST", body: body, contentType: "multipart/related; boundary=\(boundary)")
            let created = JSONHelpers.parse(responseData)
            cachedFileId = created["id"] as? String
        }
    }
}
