import Foundation

// Carries a deep-link's intent (e.g. from the CalendarWidgetExtension tapping through
// to Calendar) from RysToolsApp's .onOpenURL down to RootView, which owns the actual
// tab-selection state. A tiny shared ObservableObject rather than passing a binding
// through the App/Scene layer, since WindowGroup's content is re-created per scene.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var pendingTool: Tool?

    // rystools://calendar, rystools://scratch, rystools://email — anything else
    // (including a URL with no matching host) is silently ignored rather than treated
    // as an error, since only this app and its own widget ever construct this URL.
    func handle(_ url: URL) {
        guard url.scheme == "rystools" else { return }
        switch url.host {
        case "calendar": pendingTool = .calendar
        case "scratch": pendingTool = .scratch
        case "email": pendingTool = .email
        default: break
        }
    }
}
