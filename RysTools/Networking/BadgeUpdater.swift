import UserNotifications

// Keeps the Home Screen app icon badge in sync with the Gmail unread count. Setting a
// badge needs user authorization (the same system prompt as push notifications, just
// for the .badge option alone) — requested once, here, the first time this actually
// has something to show for.
@MainActor
enum BadgeUpdater {
    private static var didRequestAuthorization = false

    static func refresh(auth: GoogleAuthService) async {
        guard auth.isSignedIn else { return }
        if !didRequestAuthorization {
            didRequestAuthorization = true
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])
        }
        guard let count = try? await GmailService(auth: auth).unreadCount() else { return }
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}
