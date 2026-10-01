import SwiftUI

@main
struct RysToolsApp: App {
    @StateObject private var auth = GoogleAuthService.shared
    @StateObject private var appSettings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(appSettings)
                // Light mode is gone — the app is always the dark palette now, regardless
                // of the system appearance setting.
                .preferredColorScheme(.dark)
        }
    }
}
