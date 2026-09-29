import SwiftUI

// Renders an HTML email body (from GmailService.findBodyText) into something SwiftUI's
// Text can show with real formatting and tappable links — the native equivalent of
// email.html's buildEmailBody/walkEmailBody DOM walker, using Foundation's built-in
// HTML-to-NSAttributedString importer instead of a hand-written one. A free function
// (not actor-isolated) so callers can run it off the main thread via Task.detached —
// parsing HTML this way can be slow enough on a large email to jank the UI otherwise.
enum EmailBodyRenderer {
    static func render(html: String) -> AttributedString {
        guard let data = html.data(using: .utf8),
              let nsAttr = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              )
        else {
            return AttributedString(html)
        }

        // Start from plain text (dropping whatever default HTML fonts/colors WebKit's
        // importer assigned) and re-apply only the one thing worth keeping: links —
        // styled to match the app's own theme instead of a sender's arbitrary CSS.
        let plain = nsAttr.string
        var result = AttributedString(plain)
        nsAttr.enumerateAttribute(.link, in: NSRange(location: 0, length: nsAttr.length)) { value, nsRange, _ in
            let url: URL?
            if let u = value as? URL {
                url = u
            } else if let s = value as? String {
                url = URL(string: s)
            } else {
                url = nil
            }
            guard let url,
                  let stringRange = Range(nsRange, in: plain),
                  let attrRange = Range(stringRange, in: result)
            else { return }
            result[attrRange].link = url
            result[attrRange].foregroundColor = Theme.gold
            result[attrRange].underlineStyle = .single
        }
        return result
    }
}
