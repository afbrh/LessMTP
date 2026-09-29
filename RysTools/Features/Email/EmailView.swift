import QuickLook
import SwiftUI

@MainActor
final class EmailViewModel: ObservableObject {
    @Published var messages: [EmailMessage] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var emptyStateText = "Your inbox is empty."

    func load(folder: MailFolder, searchText: String, service: GmailService) async {
        isLoading = true
        errorMessage = nil
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        emptyStateText = trimmed.isEmpty
            ? "\(folder.label) is empty."
            : "No messages found for \u{201C}\(trimmed)\u{201D}."
        defer { isLoading = false }
        do {
            messages = try await service.listMessages(folder: folder, searchText: searchText)
            if folder == .inbox {
                await BadgeUpdater.refresh(auth: service.auth)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// The open inline reply composer's target — which conversation it's replying to and
// what it'll send with. See EmailView.replyArea/inlineReplyComposer.
private struct InlineReplyDraft {
    var replyTo: String
    var subject: String
    var threadId: String
}

// Uses a List (not a plain ScrollView) specifically so .swipeActions works — matching
// the web app's swipe-left-to-archive / swipe-right-to-mark-read gesture. Tapping a
// row expands it in place, in the SAME row/card, instead of pushing a new screen —
// same "tap again, or tap a different row, to collapse" behavior as the web app's
// inline accordion (only one open at a time).
struct EmailView: View {
    @EnvironmentObject var auth: GoogleAuthService
    @EnvironmentObject var appSettings: AppSettings
    @Environment(\.openURL) private var openURL
    @StateObject private var viewModel = EmailViewModel()
    @State private var expandedID: String?
    // Always an array now, even for a single message — every email renders as a
    // conversation (chat bubbles), so there's no separate single-message layout.
    @State private var expandedThread: [EmailDetail]?
    @State private var expandedBodies: [String: AttributedString] = [:]
    @State private var isLoadingDetail = false
    @State private var detailError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var composePrefill: ComposePrefill?
    @State private var quickLookURL: URL?
    @State private var downloadingAttachmentID: String?
    @State private var attachmentErrorMessage: String?
    // Reply is inline (see inlineReplyComposer) instead of the ComposeMailView sheet —
    // it opens right under the thread's chat bubbles, like typing the next message in a
    // conversation, rather than a separate To/Subject/Body screen (Forward still uses
    // the sheet, since it genuinely goes to someone new).
    @State private var inlineReply: InlineReplyDraft?
    @State private var replyText = ""
    @State private var isSendingReply = false
    @State private var replyError: String?
    @FocusState private var replyFieldFocused: Bool
    @Binding var searchText: String
    @Binding var folder: MailFolder
    // Prefers a sender's Google contact name (matching what Gmail itself shows) over
    // their raw email address in the list — see senderDisplayName(for:) and
    // GooglePeopleLookup.
    @StateObject private var contacts = GooglePeopleLookup()

    private var service: GmailService { GmailService(auth: auth) }

    var body: some View {
        List {
            if viewModel.isLoading {
                ProgressView()
                    .padding(.top, 40)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(Theme.inkSoft)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if viewModel.messages.isEmpty {
                Text(viewModel.emptyStateText)
                    .foregroundStyle(Theme.inkSoft)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.messages) { message in
                    emailRow(message)
                        // Reports this row's frame to BackgroundSwipeDetector, so a
                        // swipe here reveals archive/mark-read instead of switching tools.
                        .swipeableCard()
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        // Native swipeActions instead of a hand-built drag gesture —
                        // simpler and guaranteed not to fight the List's own scrolling.
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await archive(message) }
                            } label: {
                                swipeActionLabel(message.isArchived ? "Unarchive" : "Archive", color: LightBoxTheme.expense)
                            }
                            .tint(Theme.paper)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                Task { await toggleRead(message) }
                            } label: {
                                swipeActionLabel(message.isUnread ? "Mark read" : "Mark unread", color: LightBoxTheme.info)
                            }
                            .tint(Theme.paper)
                        }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .task { await reload() }
        .task { await contacts.loadIfNeeded(auth: auth) }
        .refreshable { await reload() }
        .onChange(of: auth.isSignedIn) { Task { await reload() } }
        .onChange(of: folder) { Task { await reload() } }
        // The search field now lives in RootView's header, next to the tool switcher,
        // instead of docking via .searchable — debounce so we're not firing a Gmail
        // query on every keystroke, but still search live without an explicit submit.
        .onChange(of: searchText) {
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
        .sheet(item: $composePrefill) { prefill in
            ComposeMailView(prefill: prefill, service: service)
        }
        .quickLookPreview($quickLookURL)
        .alert("Couldn't open attachment", isPresented: Binding(
            get: { attachmentErrorMessage != nil },
            set: { if !$0 { attachmentErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { attachmentErrorMessage = nil }
        } message: {
            Text(attachmentErrorMessage ?? "")
        }
    }

    // Reloads whatever's currently active — the selected folder plus any live search
    // text — so pull-to-refresh and folder switches always redo the right thing.
    private func reload() async {
        guard auth.isSignedIn else { return }
        await viewModel.load(folder: folder, searchText: searchText, service: service)
    }

    // Contacts name (if this address is saved) beats whatever the sender's own mail
    // client put in the "From" header, which beats falling back to the raw address —
    // matching how Mail/Messages already resolve a sender's name elsewhere on iOS.
    private func senderDisplayName(for message: EmailMessage) -> String {
        contacts.name(forEmail: extractEmailAddress(message.fromRaw)) ?? message.from
    }

    private func swipeActionLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.Font.subheadline.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(color, lineWidth: 1.5)
            )
    }

    private func emailRow(_ message: EmailMessage) -> some View {
        let isExpanded = expandedID == message.id
        // Unread rows flip to a solid white card with black text so they stand out
        // at a glance against the app's black theme; read rows keep the normal
        // paper/ink styling.
        let textColor: Color = message.isUnread ? .black : LightBoxTheme.ink

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    toggleExpanded(message)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(senderDisplayName(for: message))
                            .font(Theme.Font.subheadline)
                            .fontWeight(message.isUnread ? .bold : .semibold)
                            .foregroundStyle(LightBoxTheme.expense)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(message.subject)
                                .font(Theme.Font.subheadline)
                                .fontWeight(message.isUnread ? .bold : .regular)
                                .foregroundStyle(textColor)
                                .lineLimit(1)
                            if message.hasAttachment {
                                Image(systemName: "paperclip")
                                    .font(Theme.Font.caption2)
                                    .foregroundStyle(LightBoxTheme.inkSoft)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .trailing, spacing: 4) {
                    if let url = message.unsubscribeURL {
                        Button {
                            openURL(url)
                        } label: {
                            Text("Unsubscribe")
                                .font(Theme.Font.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(LightBoxTheme.expense)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if isExpanded {
                expandedContent(isUnread: message.isUnread)
            }
        }
        .padding(12)
        .background(message.isUnread ? Color.white : LightBoxTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(message.isUnread ? LightBoxTheme.cardBorder : .clear, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func expandedContent(isUnread: Bool) -> some View {
        let contentInk = isUnread ? Color.black : LightBoxTheme.ink
        if isLoadingDetail {
            ProgressView().padding(.vertical, 16)
        } else if let detailError {
            Text(detailError).foregroundStyle(contentInk).padding(.top, 10)
        } else if let thread = expandedThread {
            threadContent(thread, contentInk: contentInk)
        }
    }

    private func attachmentRow(_ attachment: EmailAttachment, messageId: String, contentInk: Color) -> some View {
        Button {
            Task { await openAttachment(attachment, messageId: messageId) }
        } label: {
            HStack(spacing: 6) {
                if downloadingAttachmentID == attachment.id {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: "paperclip")
                        .font(Theme.Font.caption)
                }
                Text(attachment.filename)
                    .font(Theme.Font.caption)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(formattedSize(attachment.size))
                    .font(Theme.Font.caption2)
                    .foregroundStyle(contentInk)
            }
            .foregroundStyle(contentInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LightBoxTheme.paperLine, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(downloadingAttachmentID != nil)
    }

    private func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // Downloads the attachment's bytes (a separate call — the message payload only
    // ever carries its metadata), saves it to a temp file under its real filename so
    // QuickLook can infer the right file type, then hands that off to the .quickLookPreview
    // modifier attached to the List above.
    private func openAttachment(_ attachment: EmailAttachment, messageId: String) async {
        downloadingAttachmentID = attachment.id
        defer { downloadingAttachmentID = nil }
        do {
            let data = try await service.downloadAttachment(messageId: messageId, attachmentId: attachment.id)
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(attachment.filename)
            try data.write(to: tempURL, options: .atomic)
            quickLookURL = tempURL
        } catch {
            attachmentErrorMessage = error.localizedDescription
        }
    }

    // A back-and-forth thread renders as chat bubbles instead — own messages on the
    // right, the other side's on the left — same as email.html's buildThreadContent,
    // instead of repeating the From/To header block once per message.
    private func threadContent(_ messages: [EmailDetail], contentInk: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                ForEach(messages) { message in
                    chatBubble(message, contentInk: contentInk)
                }
            }

            if let target = replyTarget(messages), let last = messages.last {
                replyArea(
                    replyTo: target.fromRaw,
                    subject: messages.first?.subject ?? "",
                    threadId: target.threadId,
                    forwardSource: last
                )
            }
        }
        .padding(.top, 10)
    }

    private func chatBubble(_ message: EmailDetail, contentInk: Color) -> some View {
        let mine = isMine(message)
        return VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            Text(mine ? shortDate(message) : "\(shortSenderName(message.from)), \(shortDate(message))")
                .font(Theme.Font.caption2)
                .foregroundStyle(LightBoxTheme.gold)
            Text(expandedBodies[message.id] ?? AttributedString(message.bodyText))
                .font(Theme.Font.subheadline)
                .foregroundStyle(contentInk)
                .padding(10)
                .background(mine ? LightBoxTheme.gold : LightBoxTheme.paperLine)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .textSelection(.enabled)
            if !message.attachments.isEmpty {
                VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        attachmentRow(attachment, messageId: message.id, contentInk: contentInk)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    // Reply opens inline (inlineReplyComposer) right where these buttons were, instead
    // of the ComposeMailView sheet — Forward still uses the sheet, since it genuinely
    // heads to someone new and needs its own To field rather than continuing this chat.
    private func replyArea(replyTo: String, subject: String, threadId: String, forwardSource: EmailDetail) -> some View {
        Group {
            if let inlineReply, inlineReply.threadId == threadId {
                inlineReplyComposer(draft: inlineReply)
            } else {
                HStack(spacing: 10) {
                    actionButton("Reply", color: LightBoxTheme.gold) {
                        inlineReply = InlineReplyDraft(
                            replyTo: replyTo,
                            subject: subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)",
                            threadId: threadId
                        )
                        replyText = ""
                        replyError = nil
                        replyFieldFocused = true
                    }
                    actionButton("Forward", color: LightBoxTheme.inkSoft) {
                        composePrefill = ComposePrefill(
                            to: "",
                            subject: subject.lowercased().hasPrefix("fwd:") ? subject : "Fwd: \(subject)",
                            body: forwardBodyText(forwardSource),
                            threadId: nil // heads to someone new, so it starts its own thread
                        )
                    }
                }
            }
        }
    }

    // A plain text field plus a Send button, styled like the chat bubbles above it —
    // typing the next reply feels like adding to the conversation, not filling out a
    // form. To/Subject aren't shown at all since a reply's recipient and subject are
    // already implied by the thread it's replying in.
    private func inlineReplyComposer(draft: InlineReplyDraft) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $replyText)
                .focused($replyFieldFocused)
                .scrollContentBackground(.hidden)
                .font(Theme.Font.subheadline)
                .foregroundStyle(LightBoxTheme.ink)
                .frame(minHeight: 70, maxHeight: 160)
                .padding(8)
                .background(LightBoxTheme.paper)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(LightBoxTheme.cardBorder, lineWidth: 1)
                )

            if let replyError {
                Text(replyError)
                    .font(Theme.Font.caption)
                    .foregroundStyle(LightBoxTheme.expense)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    inlineReply = nil
                    replyText = ""
                    replyError = nil
                    replyFieldFocused = false
                }
                .font(Theme.Font.footnote.weight(.semibold))
                .foregroundStyle(LightBoxTheme.inkSoft)

                Spacer()

                if isSendingReply {
                    ProgressView()
                } else {
                    Button {
                        Task { await sendInlineReply(draft: draft) }
                    } label: {
                        Text("Send")
                            .font(Theme.Font.footnote.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Theme.green)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // Sends, then re-fetches the thread so the just-sent message shows up as a new
    // chat bubble at the bottom — same as the rest of the conversation, sourced from
    // Gmail itself rather than a locally faked bubble that could drift from reality.
    private func sendInlineReply(draft: InlineReplyDraft) async {
        isSendingReply = true
        replyError = nil
        let openedID = expandedID
        do {
            try await service.sendMessage(
                to: draft.replyTo,
                subject: draft.subject,
                body: replyText,
                threadId: draft.threadId.isEmpty ? nil : draft.threadId
            )
            guard expandedID == openedID else { return } // collapsed mid-send
            inlineReply = nil
            replyText = ""
            isSendingReply = false
            await refreshExpandedThread(threadId: draft.threadId, openedID: openedID)
        } catch {
            replyError = error.localizedDescription
            isSendingReply = false
        }
    }

    // Mirrors toggleExpanded's own fetch — re-pulls the thread so the reply that was
    // just sent shows up as its own new bubble, just like toggleExpanded does the
    // first time a row is opened.
    private func refreshExpandedThread(threadId: String, openedID: String?) async {
        guard !threadId.isEmpty else { return }
        do {
            let messages = try await service.fetchThread(threadId: threadId)
            guard expandedID == openedID else { return }
            var bodies = expandedBodies
            for message in messages where bodies[message.id] == nil {
                bodies[message.id] = await renderedBody(message, stripQuotes: true)
            }
            guard expandedID == openedID else { return }
            expandedThread = messages
            expandedBodies = bodies
        } catch {
            // Non-fatal — the reply still sent successfully; just leave the thread
            // showing its pre-send state rather than surfacing a scary error here.
        }
    }

    private func actionButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.footnote.weight(.bold))
                .foregroundStyle(color)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .overlay(Capsule().stroke(color, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    // Standard "---------- Forwarded message ---------" block Gmail itself uses, so a
    // forward looks the same whether it started here or in Gmail proper.
    private func forwardBodyText(_ detail: EmailDetail) -> String {
        var dateLine = ""
        if let ms = Double(detail.internalDateMs) {
            let date = Date(timeIntervalSince1970: ms / 1000)
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            dateLine = "Date: \(f.string(from: date))\n"
        }
        return "---------- Forwarded message ---------\n" +
            "From: \(detail.fromRaw)\n" +
            dateLine +
            "Subject: \(detail.subject)\n" +
            "To: \(detail.to)\n\n" +
            detail.bodyText
    }

    // Reply to whoever sent the most recent message from the OTHER side — if I sent the
    // last message myself, replying should still go back to them, not to my own address.
    private func replyTarget(_ messages: [EmailDetail]) -> EmailDetail? {
        for message in messages.reversed() where !isMine(message) { return message }
        return messages.last
    }

    private func isMine(_ message: EmailDetail) -> Bool {
        guard let myEmail = auth.userEmail?.lowercased() else { return false }
        return extractEmailAddress(message.fromRaw) == myEmail
    }

    private func extractEmailAddress(_ raw: String) -> String {
        if let ltIndex = raw.firstIndex(of: "<"), let gtIndex = raw.firstIndex(of: ">"), ltIndex < gtIndex {
            return String(raw[raw.index(after: ltIndex)..<gtIndex]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return raw.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // First word of the display name ("Alex Rivera" -> "Alex") — enough to tell chat
    // bubbles apart in a thread without the full name taking up space.
    private func shortSenderName(_ displayName: String) -> String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }

    private func shortDate(_ message: EmailDetail) -> String {
        guard let ms = Double(message.internalDateMs) else { return "" }
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

    // stripQuotes cuts the quoted prior-message text a reply carries along with it —
    // pass true for chat/thread bubbles (each bubble should show only what that
    // message itself added, not the whole conversation repeated underneath it again),
    // false for the single-message view where that history is still the point of what's
    // being read.
    private func renderedBody(_ detail: EmailDetail, stripQuotes: Bool) async -> AttributedString {
        let text = stripQuotes ? Self.stripQuotedContent(detail.bodyText, isHTML: detail.isHTML) : detail.bodyText
        if detail.isHTML {
            // HTML parsing can be slow enough to jank the UI on a big email — run it off
            // the main actor, same reasoning as email.html doing its DOM walk only once
            // per expand rather than on every render.
            return await Task.detached(priority: .userInitiated) {
                EmailBodyRenderer.render(html: text)
            }.value
        }
        return AttributedString(text)
    }

    // Matches email.html's stripQuotedReply/isQuoteWrapper: cuts everything from the
    // first quote marker onward — "On <date>, <name> wrote:", Outlook's
    // "-----Original Message-----", a run of "> " quoted lines, or (HTML) Gmail's own
    // <blockquote>/gmail_quote wrapper — leaving just what was actually typed for this
    // message. A crude textual cut for HTML rather than a real DOM walk, but Gmail's
    // own reply markup reliably puts the whole quoted history in one trailing block.
    private static func stripQuotedContent(_ text: String, isHTML: Bool) -> String {
        if isHTML {
            if let range = text.range(of: "<blockquote", options: [.caseInsensitive]) {
                return String(text[..<range.lowerBound])
            }
            if let markerRange = text.range(of: "gmail_quote", options: [.caseInsensitive]),
               let divStart = text.range(of: "<div", options: [.backwards], range: text.startIndex..<markerRange.lowerBound) {
                return String(text[..<divStart.lowerBound])
            }
            return text
        }

        let lines = text.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.range(of: "^>*\\s*On\\s.{0,150}\\swrote:\\s*$", options: .regularExpression) != nil {
                return lines[0..<index].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if line.range(of: "^-{2,}\\s*Original Message\\s*-{2,}$", options: [.regularExpression, .caseInsensitive]) != nil {
                return lines[0..<index].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if index > 0, line.hasPrefix(">") {
                return lines[0..<index].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    private func toggleExpanded(_ message: EmailMessage) {
        // Collapsing (or opening a different row) always closes any open reply
        // composer too, same as switching away from a chat closes its own draft.
        inlineReply = nil
        replyText = ""
        replyError = nil
        if expandedID == message.id {
            expandedID = nil
            expandedThread = nil
            return
        }
        expandedID = message.id
        expandedThread = nil
        expandedBodies = [:]
        detailError = nil
        isLoadingDetail = true
        Task {
            do {
                // Every email renders as a conversation now, even a lone message — so
                // this always ends up with a [EmailDetail] of at least one entry,
                // whether that came from the thread endpoint or (when there's no
                // threadId at all) a single fetchFull wrapped in an array.
                var thread: [EmailDetail] = message.threadId.isEmpty ? [] : try await service.fetchThread(threadId: message.threadId)
                if thread.isEmpty {
                    thread = [try await service.fetchFull(id: message.id)]
                }
                guard expandedID == message.id else { return } // collapsed, or a different row opened, while this was in flight

                var bodies: [String: AttributedString] = [:]
                for message in thread {
                    bodies[message.id] = await renderedBody(message, stripQuotes: true)
                }
                guard expandedID == message.id else { return }
                expandedThread = thread
                expandedBodies = bodies
                isLoadingDetail = false
            } catch {
                guard expandedID == message.id else { return }
                detailError = error.localizedDescription
                isLoadingDetail = false
            }
        }
    }

    // Toggles whichever direction applies — Archive for an inbox message, Unarchive
    // (back into the inbox) for one that's already archived (only possible from search
    // results, which cover the whole mailbox). Either way it's removed from the
    // currently-shown list, matching email.html's toggleArchiveMessage.
    private func archive(_ message: EmailMessage) async {
        do {
            // A collapsed row can represent more than one message still in the inbox
            // (the whole thread) — archiving just the row's own (most recent) message
            // would leave the older ones in INBOX, and the thread would just reappear
            // on the next reload via one of those. Act on every message it stands for.
            for id in message.threadMessageIDs {
                try await service.setArchived(id: id, archived: !message.isArchived)
            }
            viewModel.messages.removeAll { $0.id == message.id }
            if expandedID == message.id { expandedID = nil }
            if message.isUnread { await BadgeUpdater.refresh(auth: auth) }
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func toggleRead(_ message: EmailMessage) async {
        do {
            for id in message.threadMessageIDs {
                try await service.markRead(id: id, unread: !message.isUnread)
            }
            if let idx = viewModel.messages.firstIndex(where: { $0.id == message.id }) {
                viewModel.messages[idx].isUnread.toggle()
            }
            await BadgeUpdater.refresh(auth: auth)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}
