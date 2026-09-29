import QuickLook
import SwiftUI

// Lets emailRow's unread dot (positioned outside the card, in the margin to its
// left) line up its vertical center with the subject text's center specifically —
// not the sender line above it, and not the card as a whole — without hand-measuring
// font line heights.
private struct SubjectLineAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.center]
    }
}

private extension VerticalAlignment {
    static let subjectLine = VerticalAlignment(SubjectLineAlignment.self)
}

// Shared by EmailView (the list) and EmailDetailView (the pushed screen) — pulls just
// the bare, lowercased address out of a "Name <addr@example.com>" header.
private func extractEmailAddress(_ raw: String) -> String {
    if let ltIndex = raw.firstIndex(of: "<"), let gtIndex = raw.firstIndex(of: ">"), ltIndex < gtIndex {
        return String(raw[raw.index(after: ltIndex)..<gtIndex]).trimmingCharacters(in: .whitespaces).lowercased()
    }
    return raw.trimmingCharacters(in: .whitespaces).lowercased()
}

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

// Uses a List (not a plain ScrollView) specifically so .swipeActions works — matching
// the web app's swipe-left-to-archive / swipe-right-to-mark-read gesture. Tapping a
// row now pushes a dedicated screen (see EmailDetailView) that slides in from the
// right, like Mail.app, instead of expanding inline in the row itself.
struct EmailView: View {
    @EnvironmentObject var auth: GoogleAuthService
    @EnvironmentObject var appSettings: AppSettings
    @Environment(\.openURL) private var openURL
    @StateObject private var viewModel = EmailViewModel()
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedMessage: EmailMessage?
    @Binding var searchText: String
    @Binding var folder: MailFolder
    // Prefers a sender's Google contact name (matching what Gmail itself shows) over
    // their raw email address in the list — see senderDisplayName(for:) and
    // GooglePeopleLookup.
    @StateObject private var contacts = GooglePeopleLookup()

    private var service: GmailService { GmailService(auth: auth) }

    var body: some View {
        NavigationStack {
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
            // RootView reserves this same height above its content via its own
            // safeAreaInset so its floating header has somewhere to sit — but once
            // this List is wrapped in a NavigationStack with its navigation bar
            // hidden (see .toolbar below, needed for the push-to-detail screen),
            // that ancestor inset stops reliably reaching down into the List, and
            // the top row ends up scrolling up partly behind the header. Reserving
            // the exact same height again here, from the inside, fixes that
            // regardless of whatever the NavigationStack does with the outer one.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: RootView.headerHeight)
            }
            .navigationDestination(item: $selectedMessage) { message in
                EmailDetailView(message: message)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
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
        // The dot sits outside the card entirely, in the blank margin to its left —
        // .subjectLine is a shared custom alignment guide (see above) so its vertical
        // center lines up exactly with the subject text's center, regardless of font
        // metrics, without needing to hand-measure line heights.
        HStack(alignment: .subjectLine, spacing: 6) {
            Circle()
                .fill(message.isUnread ? LightBoxTheme.expense : Color.clear)
                .frame(width: 8, height: 8)
                .alignmentGuide(.subjectLine) { $0[VerticalAlignment.center] }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        selectedMessage = message
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(senderDisplayName(for: message))
                                .font(Theme.Font.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(LightBoxTheme.ink)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(message.subject)
                                    .font(Theme.Font.subheadline)
                                    .fontWeight(.regular)
                                    .foregroundStyle(LightBoxTheme.inkSoft)
                                    .lineLimit(1)
                                    .alignmentGuide(.subjectLine) { $0[VerticalAlignment.center] }
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
            }
            .padding(12)
            .background(LightBoxTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .padding(.vertical, 5)
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

// The open inline reply composer's target — which conversation it's replying to and
// what it'll send with. See EmailDetailView.replyArea/inlineReplyComposer. Equatable
// so .onChange(of: inlineReply) can fire the auto-scroll-to-composer behavior.
private struct InlineReplyDraft: Equatable {
    var replyTo: String
    var subject: String
    var threadId: String
}

// The pushed, full-screen email view — slides in from the right (standard
// NavigationStack push) instead of the old inline-in-the-list expansion. Keeps the
// exact same chat-bubble thread format as before, just hosted in its own screen with
// a back button instead of inside the row it was tapped from. NavigationStack's own
// nav bar is hidden (RootView already floats its own header — search/tool
// dropdown/"+" — above everything, so a second bar here would just double up), and
// this view supplies its own minimal back row instead.
struct EmailDetailView: View {
    @EnvironmentObject var auth: GoogleAuthService
    @Environment(\.dismiss) private var dismiss
    let message: EmailMessage

    @State private var thread: [EmailDetail]?
    @State private var bodies: [String: AttributedString] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var inlineReply: InlineReplyDraft?
    @State private var replyText = ""
    @State private var isSendingReply = false
    @State private var replyError: String?
    @FocusState private var replyFieldFocused: Bool
    @State private var composePrefill: ComposePrefill?
    @State private var quickLookURL: URL?
    @State private var downloadingAttachmentID: String?
    @State private var attachmentErrorMessage: String?

    private var service: GmailService { GmailService(auth: auth) }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isLoading {
                        ProgressView().padding(.vertical, 16).frame(maxWidth: .infinity)
                    } else if let errorMessage {
                        Text(errorMessage).foregroundStyle(LightBoxTheme.ink).padding(.top, 10)
                    } else if let thread {
                        threadContent(thread)
                    }
                }
                .padding(16)
            }
            .background(Theme.paper)
            .safeAreaInset(edge: .top, spacing: 0) {
                backRow
            }
            .task { await load() }
            // Tapping Reply expands the composer right where these buttons were,
            // often below the fold on a long thread — scroll it into view instead of
            // leaving the user to find it themselves. A short delay so the composer
            // has actually appeared and laid out before scrollTo measures it; Forward
            // doesn't need this since it opens ComposeMailView as its own full sheet.
            .onChange(of: inlineReply) { _, newValue in
                guard newValue != nil else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    withAnimation { scrollProxy.scrollTo("replyArea", anchor: .bottom) }
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
    }

    private var backRow: some View {
        HStack(spacing: 4) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(Theme.Font.subheadline.weight(.semibold))
                    Text("Back")
                        .font(Theme.Font.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.paper)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            // Fetching the whole thread (not just this one message) both covers the
            // single-message case (a thread of one) and tells us whether this is
            // actually a back-and-forth conversation that should render as chat
            // bubbles instead — same as email.html's toggleInlineDetail. Every email
            // renders as a conversation now, even a lone message, so this always
            // ends up with a [EmailDetail] of at least one entry, whether that came
            // from the thread endpoint or (when there's no threadId at all) a single
            // fetchFull wrapped in an array.
            var fetched: [EmailDetail] = message.threadId.isEmpty ? [] : try await service.fetchThread(threadId: message.threadId)
            if fetched.isEmpty {
                fetched = [try await service.fetchFull(id: message.id)]
            }
            var newBodies: [String: AttributedString] = [:]
            for item in fetched {
                newBodies[item.id] = await renderedBody(item, stripQuotes: true)
            }
            thread = fetched
            bodies = newBodies
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    // A back-and-forth thread renders as chat bubbles instead — own messages on the
    // right, the other side's on the left — same as email.html's buildThreadContent,
    // instead of repeating the From/To header block once per message.
    private func threadContent(_ messages: [EmailDetail]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                ForEach(messages) { message in
                    chatBubble(message)
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
    }

    private func chatBubble(_ message: EmailDetail) -> some View {
        let mine = isMine(message)
        return VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            Text(mine ? shortDate(message) : "\(shortSenderName(message.from)), \(shortDate(message))")
                .font(Theme.Font.caption2)
                .foregroundStyle(LightBoxTheme.gold)
            Text(bodies[message.id] ?? AttributedString(message.bodyText))
                .font(Theme.Font.subheadline)
                .foregroundStyle(LightBoxTheme.ink)
                .padding(10)
                .background(mine ? LightBoxTheme.gold : LightBoxTheme.paperLine)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .textSelection(.enabled)
            if !message.attachments.isEmpty {
                VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        attachmentRow(attachment, messageId: message.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private func attachmentRow(_ attachment: EmailAttachment, messageId: String) -> some View {
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
                    .foregroundStyle(LightBoxTheme.ink)
            }
            .foregroundStyle(LightBoxTheme.ink)
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
    // modifier attached above.
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
                .padding(.top, 2)
            }
        }
        .id("replyArea")
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
        .padding(.top, 2)
    }

    // Sends, then re-fetches the thread so the just-sent message shows up as a new
    // chat bubble at the bottom — same as the rest of the conversation, sourced from
    // Gmail itself rather than a locally faked bubble that could drift from reality.
    private func sendInlineReply(draft: InlineReplyDraft) async {
        isSendingReply = true
        replyError = nil
        do {
            try await service.sendMessage(
                to: draft.replyTo,
                subject: draft.subject,
                body: replyText,
                threadId: draft.threadId.isEmpty ? nil : draft.threadId
            )
            inlineReply = nil
            replyText = ""
            isSendingReply = false
            await refreshThread(threadId: draft.threadId)
        } catch {
            replyError = error.localizedDescription
            isSendingReply = false
        }
    }

    // Mirrors load()'s own fetch — re-pulls the thread so the reply that was just
    // sent shows up as its own new bubble.
    private func refreshThread(threadId: String) async {
        guard !threadId.isEmpty else { return }
        do {
            let messages = try await service.fetchThread(threadId: threadId)
            var newBodies = bodies
            for message in messages where newBodies[message.id] == nil {
                newBodies[message.id] = await renderedBody(message, stripQuotes: true)
            }
            thread = messages
            bodies = newBodies
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

    // stripQuotes cuts the quoted prior-message text a reply carries along with it, so
    // each chat bubble shows only what that message itself added, not the whole
    // conversation repeated underneath it again.
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
}
