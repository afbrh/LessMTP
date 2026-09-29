import Foundation

// Maps an email address to Google's own contact name for it, instead of a separate
// lookup against the device's own iOS Contacts — matching whatever name Gmail
// itself already shows for a sender. Two sources, fetched once and merged into one
// dictionary: "Other contacts" (Gmail's auto-collected list of people you've
// exchanged mail with but never explicitly saved) and real saved Contacts, which
// take priority when both have an entry for the same address — mirroring Gmail's
// own preference for an explicitly-saved name over an auto-collected one.
@MainActor
final class GooglePeopleLookup: ObservableObject {
    private var nameByEmail: [String: String] = [:]
    private var hasLoaded = false

    // Safe to call repeatedly (e.g. from .task on every EmailView appearance) — only
    // does real work once per app launch.
    func loadIfNeeded(auth: GoogleAuthService) async {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard auth.isSignedIn else { return }
        let api = GoogleAPIClient(auth: auth)

        var result: [String: String] = [:]
        // Other contacts first, connections (real saved contacts) second, so a
        // genuinely saved contact's name overwrites an auto-collected one for the
        // same address rather than the other way around.
        await fetchAll(
            api: api,
            baseURL: "https://people.googleapis.com/v1/otherContacts?readMask=names,emailAddresses&pageSize=1000",
            arrayKey: "otherContacts",
            into: &result
        )
        await fetchAll(
            api: api,
            baseURL: "https://people.googleapis.com/v1/people/me/connections?personFields=names,emailAddresses&pageSize=1000",
            arrayKey: "connections",
            into: &result
        )
        nameByEmail = result
    }

    // Follows nextPageToken up to a reasonable cap — plenty for a personal account's
    // contact list, without risking an unbounded loop for an unusually large one.
    private func fetchAll(api: GoogleAPIClient, baseURL: String, arrayKey: String, into result: inout [String: String]) async {
        var pageToken: String?
        for _ in 0..<10 {
            let separator = baseURL.contains("?") ? "&" : "?"
            let url = pageToken.map { "\(baseURL)\(separator)pageToken=\($0)" } ?? baseURL
            guard let obj = try? await api.getJSON(url) else { return }
            for person in obj.array(arrayKey) {
                guard let name = Self.displayName(person) else { continue }
                for email in Self.emailAddresses(person) {
                    result[email] = name
                }
            }
            guard let nextToken = obj.string("nextPageToken"), !nextToken.isEmpty else { return }
            pageToken = nextToken
        }
    }

    private static func displayName(_ person: JSONObject) -> String? {
        guard let first = person.array("names").first else { return nil }
        let name = (first.string("displayName") ?? "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func emailAddresses(_ person: JSONObject) -> [String] {
        person.array("emailAddresses").compactMap { entry in
            let value = (entry.string("value") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return value.isEmpty ? nil : value
        }
    }

    func name(forEmail email: String) -> String? {
        nameByEmail[email.trimmingCharacters(in: .whitespaces).lowercased()]
    }
}
