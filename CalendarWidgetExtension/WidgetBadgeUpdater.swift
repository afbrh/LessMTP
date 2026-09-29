import Foundation
import UserNotifications

// Keeps the Home Screen app icon badge fresh even when the main app isn't open, by
// piggybacking on this widget's own periodic timeline refresh (same access token,
// already-valid session — no extra auth work needed). This never requests
// notification authorization itself — an extension can't present that system prompt —
// it relies on the main app's BadgeUpdater having already asked at least once.
enum WidgetBadgeUpdater {
    static func refresh(accessToken: String) async {
        guard let count = await fetchUnreadCount(accessToken: accessToken) else { return }
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }

    // Also used directly by CalendarWidget to show the same count above the Scratch
    // box, so both stay in sync from the exact same fetch logic.
    static func fetchUnreadCount(accessToken: String) async -> Int? {
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/labels/INBOX") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else { return nil }
        let obj = JSONHelpers.parse(data)
        return obj["messagesUnread"] as? Int
    }
}
