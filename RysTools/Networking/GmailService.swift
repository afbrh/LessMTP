import Foundation

struct EmailMessage: Identifiable, Hashable {
    let id: String
    let threadId: String
    // The sender's email address (not display name) of the FIRST message in the
    // thread — set in collapseByThread, overriding whichever message this struct was
    // originally built from (see fromRaw there).
    var from: String
    let fromRaw: String
    // Raw "To" header — only needed to show a recipient's name in place of the
    // sender's own name for a message the signed-in user sent (see collapseByThread).
    let toRaw: String
    let subject: String
    let date: String
    var isUnread: Bool
    // The regular inbox listing only ever contains INBOX messages, but search results
    // (which cover the whole mailbox) can include already-archived ones — swiping
    // those should offer to put them back, not archive them again.
    var isArchived: Bool
    // Every message id folded into this row (see collapseByThread) — a thread with
    // several messages still in the inbox collapses to one row, but archiving or
    // marking it read/unread needs to act on all of them, not just this row's own
    // (most recent) message, or the thread would just reappear via an older message
    // still sitting in the inbox.
    var threadMessageIDs: [String]
    // Parsed from the List-Unsubscribe header — only present for messages that
    // actually carry one (most senders that aren't running a mailing list won't).
    let unsubscribeURL: URL?
    // Whether ANY message in the thread has an attachment — set from a separate
    // has:attachment query (see fetchMessages), since Gmail's lightweight metadata
    // format doesn't include the MIME part structure needed to tell otherwise.
    var hasAttachment: Bool
}

struct EmailAttachment: Identifiable {
    let id: String // Gmail's attachmentId — needed to actually fetch its bytes
    let filename: String
    let mimeType: String
    let size: Int
}

// The folder picker in RootView's header — each maps to a Gmail search query rather
// than a labelIds filter, so it composes cleanly with the user's own search text (see
// GmailService.listMessages).
enum MailFolder: String, CaseIterable, Identifiable {
    case inbox, archive, sent, all
    var id: String { rawValue }

    var label: String {
        switch self {
        case .inbox: return "Inbox"
        case .archive: return "Archive"
        case .sent: return "Sent"
        case .all: return "All"
        }
    }

    var icon: String {
        switch self {
        case .inbox: return "tray"
        case .archive: return "archivebox"
        case .sent: return "paperplane"
        case .all: return "envelope.badge"
        }
    }

    // Gmail has no real "Archive" label — archived mail is just anything no longer in
    // INBOX — and "All" mirrors Gmail's own All Mail (everything except Spam/Trash).
    // Plain in:inbox is enough to also surface not-yet-archived sent mail: sendMessage
    // explicitly adds the INBOX label to every message it sends (new or reply), so a
    // sent item behaves exactly like a received one here — genuinely in the inbox
    // until it's actually archived, not just always visible because it was sent.
    var baseQuery: String {
        switch self {
        case .inbox: return "in:inbox"
        case .archive: return "-in:inbox -in:spam -in:trash"
        case .sent: return "in:sent"
        case .all: return "-in:spam -in:trash"
        }
    }
}

struct EmailDetail: Identifiable {
    let id: String
    let threadId: String
    let subject: String
    let from: String       // display name only, for UI
    let fromRaw: String    // raw "Name <addr>" header, needed to target a Reply correctly
    let to: String
    let bodyText: String
    let isHTML: Bool
    let internalDateMs: String
    let attachments: [EmailAttachment]
}

@MainActor
struct GmailService {
    let auth: GoogleAuthService
    private var api: GoogleAPIClient { GoogleAPIClient(auth: auth) }

    // The folder's own base query, plus the user's search text if there is any (a
    // search narrows within whichever folder is currently selected, rather than
    // always searching the whole mailbox).
    func listMessages(folder: MailFolder, searchText: String, max: Int = 25) async throws -> [EmailMessage] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = trimmedSearch.isEmpty ? folder.baseQuery : "\(folder.baseQuery) \(trimmedSearch)"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try await fetchMessages(
            listURL: "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=\(max)&q=\(encoded)",
            attachmentQuery: "\(query) has:attachment"
        )
    }

    // The INBOX label's own messagesUnread count — the true total, not just however
    // many rows happen to be in the current list (which is capped at `max`). Used to
    // keep the Home Screen app icon badge accurate.
    func unreadCount() async throws -> Int {
        let url = "https://gmail.googleapis.com/gmail/v1/users/me/labels/INBOX"
        let obj = try await api.getJSON(url)
        return (obj["messagesUnread"] as? Int) ?? 0
    }

    private func fetchMessages(listURL: String, attachmentQuery: String) async throws -> [EmailMessage] {
        // The attachment check rides alongside the main list fetch (same underlying
        // query, plus has:attachment) rather than after it — Gmail's lightweight
        // metadata format has no MIME part info to check this from directly, and a
        // second id-only list call is far cheaper than fetching format=full for
        // every row just to find out.
        async let listResult = api.getJSON(listURL)
        async let attachmentIDsResult = attachmentMessageIDs(query: attachmentQuery)
        let (listObj, attachmentIDs) = try await (listResult, attachmentIDsResult)
        let refs = listObj.array("messages")

        // Fetch each message's headers concurrently, same as email.html's
        // Promise.all(refs.map(...)) — much faster than one at a time.
        return try await withThrowingTaskGroup(of: EmailMessage?.self) { group in
            for ref in refs {
                guard let id = ref["id"] as? String else { continue }
                group.addTask {
                    try? await self.fetchMetadata(id: id, hasAttachment: attachmentIDs.contains(id))
                }
            }
            var results: [EmailMessage] = []
            for try await item in group {
                if let item { results.append(item) }
            }
            return Self.collapseByThread(results.sorted { $0.id > $1.id }, myEmail: auth.userEmail)
        }
    }

    // A lightweight id-only list, used only to know WHICH of the messages already
    // being fetched have an attachment — failures here just mean no rows get the
    // paperclip indicator, not a broken list.
    private func attachmentMessageIDs(query: String) async throws -> Set<String> {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=100&q=\(encoded)"
        guard let obj = try? await api.getJSON(url) else { return [] }
        return Set(obj.array("messages").compactMap { $0["id"] as? String })
    }

    // Gmail's messages.list returns one entry per MESSAGE, so a thread with several
    // messages still in the inbox (a kept reply chain) would otherwise show up as
    // several separate rows — collapse those to a single row per thread instead,
    // matching Gmail's own inbox. Keeps the most recent message's subject/date, but
    // shows the sender's email address of the OLDEST message in the thread (per the
    // "first email in the whole thread" ask) — a scan only of whatever's in THIS
    // fetched batch, so a thread whose true opening message was archived out of this
    // list won't be seen; within a kept-together thread it's exact. Shows unread if
    // ANY message in the thread still is, and remembers every id folded in so
    // archiving/marking read can apply to the whole thread, not just this one row.
    // myEmail lets a thread I started myself (oldest message sent BY me, not a reply
    // to anyone) show who I sent it to instead of my own name, which is useless in a
    // unified inbox that already implies "me" as a participant everywhere.
    private static func collapseByThread(_ messages: [EmailMessage], myEmail: String?) -> [EmailMessage] {
        var order: [String] = []
        var idsByThread: [String: [String]] = [:]
        var unreadByThread: [String: Bool] = [:]
        var hasAttachmentByThread: [String: Bool] = [:]
        var representative: [String: EmailMessage] = [:]
        var oldestFromRawByThread: [String: String] = [:]
        var oldestToRawByThread: [String: String] = [:]

        for message in messages {
            if representative[message.threadId] == nil {
                order.append(message.threadId)
                representative[message.threadId] = message
            }
            idsByThread[message.threadId, default: []].append(message.id)
            unreadByThread[message.threadId, default: false] = unreadByThread[message.threadId, default: false] || message.isUnread
            hasAttachmentByThread[message.threadId, default: false] = hasAttachmentByThread[message.threadId, default: false] || message.hasAttachment
            // messages is sorted newest-first, so the last write per thread ends up
            // being the oldest message seen for it.
            oldestFromRawByThread[message.threadId] = message.fromRaw
            oldestToRawByThread[message.threadId] = message.toRaw
        }

        let myEmailLower = myEmail?.lowercased()
        return order.map { threadId in
            var rep = representative[threadId]!
            rep.isUnread = unreadByThread[threadId] ?? rep.isUnread
            rep.hasAttachment = hasAttachmentByThread[threadId] ?? rep.hasAttachment
            rep.threadMessageIDs = idsByThread[threadId] ?? [rep.id]
            if let oldestFromRaw = oldestFromRawByThread[threadId] {
                if let myEmailLower, extractEmailAddress(oldestFromRaw) == myEmailLower,
                   let oldestToRaw = oldestToRawByThread[threadId], !oldestToRaw.isEmpty {
                    rep.from = displayName(oldestToRaw)
                } else {
                    rep.from = displayName(oldestFromRaw)
                }
            }
            return rep
        }
    }

    // The header looks like `<https://example.com/unsub?id=1>, <mailto:unsub@x.com>` —
    // pull out every bracketed URL and prefer an https one (a one-tap web unsubscribe)
    // over a mailto (which just opens a compose window addressed to it).
    private static func parseListUnsubscribe(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        let urls = raw.split(separator: ",").compactMap { part -> URL? in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else { return nil }
            return URL(string: String(trimmed.dropFirst().dropLast()))
        }
        return urls.first { $0.scheme == "https" || $0.scheme == "http" } ?? urls.first
    }

    private func fetchMetadata(id: String, hasAttachment: Bool) async throws -> EmailMessage {
        let url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject&metadataHeaders=List-Unsubscribe"
        let obj = try await api.getJSON(url)
        let headers = (obj.object("payload").array("headers"))
        func header(_ name: String) -> String {
            headers.first { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }?["value"] as? String ?? ""
        }
        let labelIds = obj["labelIds"] as? [String] ?? []
        let fromRaw = header("From")
        return EmailMessage(
            id: id,
            threadId: (obj["threadId"] as? String) ?? "",
            from: Self.displayName(fromRaw), // overwritten in collapseByThread with the thread's oldest sender's address
            fromRaw: fromRaw,
            toRaw: header("To"),
            subject: header("Subject").isEmpty ? "(no subject)" : header("Subject"),
            date: formatDate(internalDateMs: obj["internalDate"] as? String ?? ""),
            isUnread: labelIds.contains("UNREAD"),
            isArchived: !labelIds.contains("INBOX"),
            threadMessageIDs: [id],
            unsubscribeURL: Self.parseListUnsubscribe(header("List-Unsubscribe")),
            hasAttachment: hasAttachment
        )
    }

    // Matches email.html's displayName(): a raw From header is usually
    // `"Name" <addr@example.com>` or `Name <addr@example.com>` — strip the address and
    // quoting so the list just shows the human name, falling back to the raw header
    // (e.g. a bare address with no name) when there's nothing to strip.
    private static func displayName(_ raw: String) -> String {
        guard let ltIndex = raw.firstIndex(of: "<") else {
            return raw.isEmpty ? "(unknown sender)" : raw
        }
        var name = String(raw[..<ltIndex]).trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        return name.isEmpty ? raw : name
    }

    // Pulls just the bare, lowercased address out of a "Name <addr@example.com>"
    // header, for comparing against the signed-in user's own address — same parsing
    // as displayName, just keeping the bracketed part instead of discarding it.
    private static func extractEmailAddress(_ raw: String) -> String {
        if let ltIndex = raw.firstIndex(of: "<"), let gtIndex = raw.firstIndex(of: ">"), ltIndex < gtIndex {
            return String(raw[raw.index(after: ltIndex)..<gtIndex]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return raw.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // Matches email.html's formatDate(): today's messages show just a time
    // ("2:34 PM"), older ones show a short date ("Sep 20") — using Gmail's own
    // internalDate (ms since epoch) rather than the raw, inconsistently-formatted
    // Date header.
    private func formatDate(internalDateMs: String) -> String {
        guard let ms = Double(internalDateMs) else { return "" }
        let date = Date(timeIntervalSince1970: ms / 1000)
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }

    func fetchFull(id: String) async throws -> EmailDetail {
        let url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full"
        let obj = try await api.getJSON(url)
        return parseDetail(obj)
    }

    // Every message in a thread, oldest-first (Gmail's own ordering) — one request
    // instead of one per message. A thread of exactly one message is exactly the
    // single-message case; more than one is a real back-and-forth conversation, which
    // EmailView renders as chat bubbles instead of the plain single-message layout.
    func fetchThread(threadId: String) async throws -> [EmailDetail] {
        let url = "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(threadId)?format=full"
        let obj = try await api.getJSON(url)
        return obj.array("messages").map(parseDetail)
    }

    private func parseDetail(_ obj: JSONObject) -> EmailDetail {
        let payload = obj.object("payload")
        let headers = payload.array("headers")
        func header(_ name: String) -> String {
            headers.first { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }?["value"] as? String ?? ""
        }
        let fromRaw = header("From")
        let (text, isHTML) = findBodyText(payload)
        return EmailDetail(
            id: (obj["id"] as? String) ?? "",
            threadId: (obj["threadId"] as? String) ?? "",
            subject: header("Subject").isEmpty ? "(no subject)" : header("Subject"),
            from: Self.displayName(fromRaw),
            fromRaw: fromRaw,
            to: header("To"),
            bodyText: text.isEmpty ? "(No readable body.)" : text,
            isHTML: isHTML,
            internalDateMs: (obj["internalDate"] as? String) ?? "",
            attachments: extractAttachments(payload)
        )
    }

    // A real attachment part always has both a non-empty filename and a
    // body.attachmentId (its content isn't inlined into this response — a separate
    // attachments.get call is needed to actually fetch the bytes, see
    // downloadAttachment). Walks the whole MIME tree since attachments can sit
    // alongside nested multipart/alternative body parts.
    private func extractAttachments(_ payload: JSONObject) -> [EmailAttachment] {
        var results: [EmailAttachment] = []
        func walk(_ part: JSONObject) {
            let filename = part["filename"] as? String ?? ""
            let body = part.object("body")
            if !filename.isEmpty, let attachmentId = body["attachmentId"] as? String {
                results.append(EmailAttachment(
                    id: attachmentId,
                    filename: filename,
                    mimeType: (part["mimeType"] as? String) ?? "application/octet-stream",
                    size: (body["size"] as? Int) ?? 0
                ))
            }
            for sub in part.array("parts") {
                walk(sub)
            }
        }
        walk(payload)
        return results
    }

    // Attachments aren't included in a message's own payload (just their metadata,
    // via extractAttachments above) — the actual bytes need this separate call,
    // base64url-encoded same as everything else in the Gmail API.
    func downloadAttachment(messageId: String, attachmentId: String) async throws -> Data {
        let url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageId)/attachments/\(attachmentId)"
        let obj = try await api.getJSON(url)
        guard let data = obj["data"] as? String else { throw APIError.http(0, "No attachment data.") }
        var b64 = data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let decoded = Data(base64Encoded: b64) else { throw APIError.http(0, "Couldn't decode attachment.") }
        return decoded
    }

    // Matches email.html's send(): a plain-text MIME message, base64url-encoded into
    // Gmail's `raw` field. Passing threadId sends it as a reply within that
    // conversation; omitting it (a Forward, or a fresh message) starts a new one.
    func sendMessage(to: String, subject: String, body: String, threadId: String?) async throws {
        let mime = "To: \(to)\r\nSubject: \(subject)\r\nContent-Type: text/plain; charset=\"UTF-8\"\r\nMIME-Version: 1.0\r\n\r\n\(body)"
        guard let mimeData = mime.data(using: .utf8) else { throw APIError.http(0, "Couldn't encode message.") }
        let raw = mimeData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var requestBody: JSONObject = ["raw": raw]
        if let threadId { requestBody["threadId"] = threadId }
        let url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"
        let responseData = try await api.send(url, method: "POST", body: JSONHelpers.serialize(requestBody))

        // Gmail never tags a message YOU send with INBOX on its own — only an
        // incoming reply into an already-inboxed thread keeps that label. Without
        // this, a sent message (new or reply) would have no INBOX label to lose,
        // making Archive/Unarchive on it in the Inbox tab a no-op forever. Adding it
        // explicitly here puts every sent message on equal footing with a received
        // one: genuinely "in the inbox" until actually archived.
        let sentObj = JSONHelpers.parse(responseData)
        if let sentId = sentObj.string("id") {
            try? await setArchived(id: sentId, archived: false)
        }
    }

    // Matches email.html's findBodyText(): prefers text/html over text/plain (flipped
    // from an earlier version that preferred plain text). In practice, a sender's
    // plain-text alternative is often a naive dump — a "View your order" button in the
    // HTML version becomes its full, often huge, tracking URL spelled out inline in the
    // plain-text one — so the HTML version (rendered properly, not tag-stripped) is the
    // better default whenever a sender bothers to provide it. Gmail bodies are
    // base64url-encoded and can be nested across multipart/alternative parts.
    private func findBodyText(_ payload: JSONObject) -> (text: String, isHTML: Bool) {
        func decode(_ obj: JSONObject) -> String? {
            guard let data = obj.object("body")["data"] as? String else { return nil }
            var b64 = data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            guard let raw = Data(base64Encoded: b64) else { return nil }
            return String(data: raw, encoding: .utf8)
        }

        if (payload["mimeType"] as? String) == "text/html", let text = decode(payload), !text.isEmpty {
            return (text, true)
        }
        if (payload["mimeType"] as? String) == "text/plain", let text = decode(payload), !text.isEmpty {
            return (text, false)
        }
        let parts = payload.array("parts")
        if !parts.isEmpty {
            var plainFallback: (text: String, isHTML: Bool)?
            for part in parts {
                let found = findBodyText(part)
                if !found.text.isEmpty && found.isHTML { return found }
                if !found.text.isEmpty && !found.isHTML && plainFallback == nil { plainFallback = found }
            }
            if let plainFallback { return plainFallback }
        }
        return ("", false)
    }

    func markRead(id: String, unread: Bool) async throws {
        let url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)/modify"
        let body: JSONObject = unread ? ["addLabelIds": ["UNREAD"]] : ["removeLabelIds": ["UNREAD"]]
        _ = try await api.send(url, method: "POST", body: JSONHelpers.serialize(body))
    }

    func setArchived(id: String, archived: Bool) async throws {
        let url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)/modify"
        let body: JSONObject = archived ? ["removeLabelIds": ["INBOX"]] : ["addLabelIds": ["INBOX"]]
        _ = try await api.send(url, method: "POST", body: JSONHelpers.serialize(body))
    }
}
