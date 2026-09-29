import SwiftUI

// Mirrors the CSS custom properties in budget.html/email.html/cal.html/scratch.html
// (--paper, --ink, --gold, etc.), light and dark, so the native app reads as the same
// app rather than a from-scratch design.
enum Theme {
    static func dynamic(light: String, dark: String) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    static func fixed(_ hex: String) -> Color { Color(uiColor: UIColor(hex: hex)) }

    static let paper = dynamic(light: "#F3E9CE", dark: "#000000")
    static let paperLine = dynamic(light: "#D9C79C", dark: "#1C1C1C")
    static let ink = dynamic(light: "#3B2A16", dark: "#F0F0EA")
    static let inkSoft = dynamic(light: "#7A6142", dark: "#8C8C84")
    static let income = dynamic(light: "#3F6B33", dark: "#6FCF7A")
    static let incomeBg = dynamic(light: "#E4EDD7", dark: "#101F13")
    static let expense = dynamic(light: "#93402A", dark: "#E2685A")
    static let expenseBg = dynamic(light: "#F1DCC9", dark: "#241211")
    static let gold = dynamic(light: "#8A6423", dark: "#D9B25E")
    static let goldBg = dynamic(light: "#EBDBAF", dark: "#1F1A0E")
    // Blue accent — used for the E-Mail swipe-to-mark-read/unread action, which has no
    // pre-existing color of its own (unlike archive, which reuses `expense`'s red).
    static let info = dynamic(light: "#2B4C7E", dark: "#6FA8DC")
    // Fixed (not light/dark adaptive) dark grey for the Email header's folder picker,
    // search field, and compose button — a deliberately different fill from the
    // screen's own pure-black background so those controls read as buttons.
    static let darkGrey = fixed("#2A2A2A")
    // Fixed solid green fill for "primary create" actions (Calendar's Create Event,
    // Email's Compose) — a deliberately different, more saturated accent from the
    // muted income green above, so it reads as a button rather than a status color.
    static let green = fixed("#2E8B57")
}

// Everywhere else in the app now always uses Theme's dark palette (see
// RysToolsApp's forced .preferredColorScheme(.dark) — light mode is gone). Email's
// message boxes and Calendar's day squares/event cards are the deliberate exception:
// they keep their own fixed "card" look — independent of system appearance — driven
// by AppSettings.shared.cardColor (fixed to .black — this used to be user-editable
// via a Settings screen that's since been removed entirely). `paper` is that chosen
// color; `ink`/`inkSoft`/
// `paperLine` flip to white-based tones automatically on a dark card (black, dark
// grey) so text stays legible, rather than staying pinned to black and going
// unreadable on a black card. `gold`/`expense`/`info` stay fixed accent colors, same
// as before — they're brand/semantic colors, not about card contrast. Cards have no
// border of their own for Beige/White — `paper` alone sets a card apart from the
// screen behind it — except the two dark choices (Dark Grey, Black), which sit close
// to the screen's own near-black/pure-black chrome with little to no contrast
// otherwise, so they get a faint outline (`cardBorder`) just to stay visible as their
// own shape at all.
// @MainActor because AppCardColor comes from AppSettings.shared, a @MainActor type
// (this file also compiles into the widget extension target, where that isolation
// must be explicit).
@MainActor
enum LightBoxTheme {
    static var paper: Color { AppSettings.shared.cardColor.paper }
    static var ink: Color { AppSettings.shared.cardColor.needsLightInk ? .white : .black }
    static var inkSoft: Color { ink.opacity(0.55) }
    static var paperLine: Color { ink.opacity(0.25) }
    static var cardBorder: Color { AppSettings.shared.cardColor.needsLightInk ? Color.white.opacity(0.18) : .clear }
    // Email timestamps, chat-bubble accents, the Reply button, Calendar's dots/today
    // marker, checkmarks, etc. all use this — same reasoning as `expense` below: the
    // darker gold was tuned for a light card and reads as low-contrast on a dark one,
    // so dark cards get the same lighter gold Theme's own dark-mode chrome already uses.
    static var gold: Color {
        AppSettings.shared.cardColor.needsLightInk ? Theme.fixed("#D9B25E") : Theme.fixed("#8A6423")
    }
    // Unread email text, the Archive/Unsubscribe actions, and reply errors all use
    // this — the darker red was tuned for a light card (Beige/White) and reads as
    // low-contrast/muddy on a dark one (Dark Grey/Black), so dark cards get the same
    // lighter coral-red Theme's own dark-mode chrome already uses elsewhere.
    static var expense: Color {
        AppSettings.shared.cardColor.needsLightInk ? Theme.fixed("#E2685A") : Theme.fixed("#93402A")
    }
    static let info = Theme.fixed("#2B4C7E")
}

// The Settings tool's "Look and Feel > Font" choice, applied here rather than at each
// call site — every semantic size (Theme.Font.headline, .subheadline, etc.) mirrors
// SwiftUI's own built-in text styles exactly when the choice is Default, and swaps in
// the chosen family (still scaling with Dynamic Type via `relativeTo`) otherwise.
extension Theme {
    @MainActor
    enum Font {
        static var largeTitle: SwiftUI.Font { styled(.largeTitle, size: 34) }
        static var title: SwiftUI.Font { styled(.title, size: 28) }
        static var title2: SwiftUI.Font { styled(.title2, size: 22) }
        static var title3: SwiftUI.Font { styled(.title3, size: 20) }
        static var headline: SwiftUI.Font { styled(.headline, size: 17) }
        static var body: SwiftUI.Font { styled(.body, size: 17) }
        static var callout: SwiftUI.Font { styled(.callout, size: 16) }
        static var subheadline: SwiftUI.Font { styled(.subheadline, size: 15) }
        static var footnote: SwiftUI.Font { styled(.footnote, size: 13) }
        static var caption: SwiftUI.Font { styled(.caption, size: 12) }
        static var caption2: SwiftUI.Font { styled(.caption2, size: 11) }

        static func custom(size: CGFloat) -> SwiftUI.Font {
            guard let familyName = AppSettings.shared.font.familyName else {
                return .system(size: size)
            }
            return .custom(familyName, size: size)
        }

        private static func styled(_ style: SwiftUI.Font.TextStyle, size: CGFloat) -> SwiftUI.Font {
            guard let familyName = AppSettings.shared.font.familyName else {
                return .system(style)
            }
            return .custom(familyName, size: size, relativeTo: style)
        }
    }
}

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255
        let b = CGFloat(rgb & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

