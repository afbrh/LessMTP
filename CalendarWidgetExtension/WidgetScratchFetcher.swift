import Foundation

// A trimmed, self-contained copy of DriveStore.loadTools's Drive-file lookup for this
// extension — same reasoning as WidgetCalendarFetcher: DriveStore is built around
// GoogleAuthService, which isn't usable here (see WidgetAuth).
enum WidgetScratchFetcher {
    private static let fileName = "munny-data.json"

    // Only the first box's text — the medium widget only has room to show one, and it
    // matches "the top box from Scratch."
    static func fetchFirstBox(accessToken: String) async -> String? {
        guard let fileId = await findFileId(accessToken: accessToken) else { return nil }
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return nil }

        let obj = JSONHelpers.parse(data)
        let text = obj.object("tools").object("scratch").string("text") ?? ""
        let firstBox = text.components(separatedBy: "\n\n\n").first ?? text
        let trimmed = firstBox.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func findFileId(accessToken: String) async -> String? {
        let q = "name='\(fileName)' and trashed=false"
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files?q=\(encoded)&spaces=drive&fields=files(id,name)")
        else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return nil }
        let obj = JSONHelpers.parse(data)
        return obj.array("files").first?["id"] as? String
    }
}
