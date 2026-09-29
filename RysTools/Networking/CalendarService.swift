import Foundation

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let start: Date?
    let end: Date?
    let isAllDay: Bool
    let location: String?
    let description: String?
    let htmlLink: String?
    // Present only on an instance of a recurring series (singleEvents=true expands
    // each occurrence to its own item, each carrying the master event's id here).
    let recurringEventId: String?
    // Present only on a series' own master event (never on an individual instance) —
    // the raw RRULE/EXDATE/etc. lines, e.g. ["RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=10"].
    let recurrenceRules: [String]?
}

@MainActor
struct CalendarService {
    let auth: GoogleAuthService
    private var api: GoogleAPIClient { GoogleAPIClient(auth: auth) }

    // The native app's Upcoming box is sized to exactly half the screen (unlike the
    // web app's smaller fixed-height one) and shows as many events as fit that space
    // without scrolling — so this over-fetches a generous buffer rather than the web
    // app's fixed 3, and CalendarView's own fixed-height, non-scrolling List just
    // clips whatever doesn't fit.
    func listUpcoming(max: Int = 10) async throws -> [CalendarEvent] {
        let timeMin = isoString(Date())
        let url = "https://www.googleapis.com/calendar/v3/calendars/primary/events" +
            "?timeMin=\(encode(timeMin))&singleEvents=true&orderBy=startTime&maxResults=\(max)"
        return try await fetchEvents(url)
    }

    // For the month grid — every event whose start falls within [from, to), used both
    // for each day's chip dots and for a tapped day's event list (no separate request
    // needed once the month's already loaded).
    func listEvents(from: Date, to: Date) async throws -> [CalendarEvent] {
        let url = "https://www.googleapis.com/calendar/v3/calendars/primary/events" +
            "?timeMin=\(encode(isoString(from)))&timeMax=\(encode(isoString(to)))&singleEvents=true&orderBy=startTime&maxResults=250"
        return try await fetchEvents(url)
    }

    private func fetchEvents(_ url: String) async throws -> [CalendarEvent] {
        let obj = try await api.getJSON(url)
        return obj.array("items").map(parseEvent)
    }

    // Fetches a single event by id — used to load a recurring series' own master event
    // (id == an instance's recurringEventId) for "Edit" (the whole series), as opposed
    // to "Edit Occurrence" which edits the already-in-hand instance directly.
    func fetchEvent(id: String) async throws -> CalendarEvent {
        let url = "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(id)"
        let obj = try await api.getJSON(url)
        return parseEvent(obj)
    }

    private func parseEvent(_ item: JSONObject) -> CalendarEvent {
        let startObj = item.object("start")
        let isAllDay = startObj["dateTime"] == nil
        let start = parseDate(startObj)
        let end = parseDate(item.object("end"))
        return CalendarEvent(
            id: (item["id"] as? String) ?? UUID().uuidString,
            title: (item["summary"] as? String) ?? "(no title)",
            start: start,
            end: end,
            isAllDay: isAllDay,
            location: item["location"] as? String,
            description: item["description"] as? String,
            htmlLink: item["htmlLink"] as? String,
            recurringEventId: item["recurringEventId"] as? String,
            recurrenceRules: item["recurrence"] as? [String]
        )
    }

    private func parseDate(_ obj: JSONObject) -> Date? {
        if let dt = obj["dateTime"] as? String {
            return ISO8601DateFormatter().date(from: dt)
        } else if let d = obj["date"] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            return f.date(from: d)
        }
        return nil
    }

    // Title, Location, and either a start/end time pair (timed event) or a start/end day
    // pair (all-day event, possibly spanning multiple days).
    func createEvent(title: String, location: String, start: Date?, end: Date?, day: Date, endDay: Date) async throws {
        let url = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
        var resource: JSONObject = ["summary": title]
        if !location.isEmpty { resource["location"] = location }
        if let start, let end {
            resource["start"] = ["dateTime": isoString(start)]
            resource["end"] = ["dateTime": isoString(end)]
        } else {
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            resource["start"] = ["date": dateOnlyString(day)]
            resource["end"] = ["date": dateOnlyString(nextDay)] // exclusive end, per the API
        }
        _ = try await api.send(url, method: "POST", body: JSONHelpers.serialize(resource))
    }

    // Location is sent unconditionally (even ''), unlike createEvent — a PATCH only
    // touches fields present in the body, so omitting it when the field was cleared
    // during an edit would silently leave the old location in place. recurrence is
    // only passed when editing a series' own master event (nil otherwise, including
    // every non-recurring edit and every single-occurrence edit — an instance can't
    // carry its own recurrence rule, only the master can).
    func updateEvent(id: String, title: String, location: String, start: Date?, end: Date?, day: Date, endDay: Date, recurrence: [String]? = nil) async throws {
        let url = "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(id)"
        var resource: JSONObject = ["summary": title, "location": location]
        if let start, let end {
            resource["start"] = ["dateTime": isoString(start)]
            resource["end"] = ["dateTime": isoString(end)]
        } else {
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            resource["start"] = ["date": dateOnlyString(day)]
            resource["end"] = ["date": dateOnlyString(nextDay)]
        }
        if let recurrence { resource["recurrence"] = recurrence }
        _ = try await api.send(url, method: "PATCH", body: JSONHelpers.serialize(resource))
    }

    func deleteEvent(id: String) async throws {
        let url = "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(id)"
        _ = try await api.send(url, method: "DELETE", body: nil)
    }

    private func dateOnlyString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    private func isoString(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
}
