import SwiftUI

// The whole app's chosen "look and feel" font. iOS ships every one of these families
// already (no font files to bundle) — Font.custom just needs the right PostScript name.
enum AppFontChoice: String, CaseIterable, Identifiable {
    case system, typewriter, console, verdana, georgia
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .typewriter: return "Typewriter"
        case .console: return "Console"
        case .verdana: return "Verdana"
        case .georgia: return "Georgia"
        }
    }

    // nil means "just use the system font" — Theme.Font falls back to SwiftUI's own
    // .headline/.subheadline/etc. (San Francisco, whatever the current iOS default
    // actually is) rather than reconstructing them, so System always matches exactly
    // whatever the app already looked like before this setting existed.
    var familyName: String? {
        switch self {
        case .system: return nil
        case .typewriter: return "AmericanTypewriter"
        case .console: return "Menlo"
        case .verdana: return "Verdana"
        case .georgia: return "Georgia"
        }
    }
}

// The color of every "card" (each email row) — what LightBoxTheme.paper actually
// resolves to. Beige is the original,
// long-standing look and stays the default; the other three are plain, deliberately
// simple choices rather than a full palette.
enum AppCardColor: String, CaseIterable, Identifiable {
    case white, beige, darkGrey, black
    var id: String { rawValue }

    var label: String {
        switch self {
        case .beige: return "Beige"
        case .darkGrey: return "Dark Grey"
        case .black: return "Black"
        case .white: return "White"
        }
    }

    var paper: Color {
        switch self {
        case .beige: return Theme.fixed("#F3E9CE")
        case .darkGrey: return Theme.fixed("#2A2A2A")
        case .black: return Color.black
        case .white: return Color.white
        }
    }

    // Whether text/borders drawn on top of this card need to flip to white instead of
    // the usual black — otherwise a dark card would read as black-on-black.
    var needsLightInk: Bool {
        switch self {
        case .beige, .white: return false
        case .darkGrey, .black: return true
        }
    }
}

// One shared instance (not per-view state), read by Theme.Font/LightBoxTheme
// throughout the app. font/cardColor used to be user-editable (a Settings screen,
// persisted per-device) — per an explicit ask to drop that editing UI entirely,
// they're now just fixed values: System font, Black cards. Still an ObservableObject
// (rather than a plain enum/static values) purely so every existing
// `@EnvironmentObject var appSettings: AppSettings` across the app keeps compiling
// unchanged; nothing ever publishes a change to these any more.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    let font: AppFontChoice = .system
    let cardColor: AppCardColor = .black

    private init() {}
}
