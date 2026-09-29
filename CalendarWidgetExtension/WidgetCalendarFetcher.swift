import Foundation

struct WidgetEvent: Identifiable {
    let id: String
    let title: String
    let start: Date?
    let isAllDay: Bool
}

// A trimmed, self-contained copy of CalendarService.listUpcoming/parseEvent for this
// extension — kept separate rather than sharing CalendarService directly, since that
// type is built around GoogleAuthService (not usable here, see WidgetAuth).
enum WidgetCalendarFetcher {
    static func fetchUpcoming(accessToken: String, max: Int = 4) async -> [WidgetEvent] {
        let isoNow = ISO8601DateFormatter().string(from: Date())
        let encoded = isoNow.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? isoNow
        let urlString = "https://www.googleapis.com/calendar/v3/calendars/primary/events" +
            "?timeMin=\(encoded)&singleEvents=true&orderBy=startTime&maxResults=\(max)"
        guard let url = URL(string: urlString) else { return [] }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else { return [] }

        let obj = JSONHelpers.parse(data)
        return obj.array("items").map(parseEvent)
    }

    private static func parseEvent(_ item: JSONObject) -> WidgetEvent {
        let startObj = item.object("start")
        let isAllDay = startObj["dateTime"] == nil
        let start: Date?
        if let dt = startObj["dateTime"] as? String {
            start = ISO8601DateFormatter().date(from: dt)
        } else if let d = startObj["date"] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            start = f.date(from: d)
        } else {
            start = nil
        }
        return WidgetEvent(
            id: (item["id"] as? String) ?? UUID().uuidString,
            title: (item["summary"] as? String) ?? "(no title)",
            start: start,
            isAllDay: isAllDay
        )
    }
}
