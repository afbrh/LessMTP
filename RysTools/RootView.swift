import SwiftUI

// No dedicated tool-switcher bar any more, and no NavigationStack either — like the
// web app, this is flat content-swapping under one header. Navigation between tools
// (and mail folders, and signing in/out) all happens through one dropdown menu in
// the header (see navMenu below) instead — per an explicit ask to remove the old
// full-width tool-switcher row entirely and make that dropdown the one way to get
// around the app from now on.
enum Tool: String, CaseIterable, Identifiable {
    case email, calendar, scratch
    var id: String { rawValue }

    var label: String {
        switch self {
        case .email: return "E-Mail"
        case .calendar: return "Calendar"
        case .scratch: return "Note"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var auth: GoogleAuthService
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var router: AppRouter
    @State private var selectedTool: Tool = .email
    @State private var emailSearchText = ""
    // Calendar's matches event titles against everything already loaded for the
    // month grid (see CalendarView.searchResultEvents). Note has no search of its
    // own — a single continuous block of text has nothing meaningful to filter.
    @State private var calendarSearchText = ""
    @State private var selectedFolder: MailFolder = .inbox
    @State private var isNavMenuOpen = false
    @State private var isSearchExpanded = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var composePrefill: ComposePrefill?
    // Flipped true by the header's "+" button (see headerBar) when on Calendar, then
    // immediately flipped back by the screen that's listening for it — same
    // "+"-in-the-header spot Email's Compose button already used. Note has no "+" of
    // its own since there's only ever the one note.
    @State private var triggerCalendarCreate = false
    // Collected from every currently on-screen .swipeableCard() (email rows,
    // calendar events) — see BackgroundSwipeDetector.
    @State private var swipeableCardFrames: [CGRect] = []

    // The header floats over the content instead of sitting in its own row (it has its
    // own opaque background — see headerBar — so scrolled content disappears behind
    // it rather than showing through), but at rest, content should start right below
    // the header, not under it. Now that the header is just one row, shown identically
    // regardless of selectedTool or sign-in state (search/compose are the only parts
    // that ever come and go, and neither changes the row's own height), this is a
    // single fixed constant instead of a per-state calculation.
    private let headerHeight: CGFloat = 64

    var body: some View {
        ZStack(alignment: .top) {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: headerHeight)
                }
                // Lets a swipe anywhere in the content area switch tools too, not just
                // on the header title. See BackgroundSwipeDetector for why this is a
                // real UIPanGestureRecognizer on the window rather than a SwiftUI
                // .simultaneousGesture: it can reject a touch outright when it starts on
                // a List row, so a card's own native .swipeActions (archive, delete)
                // always wins there instead of racing this on distance/angle alone.
                .onPreferenceChange(SwipeableCardFramesKey.self) { swipeableCardFrames = $0 }
                .background(BackgroundSwipeDetector(
                    swipeableCardFrames: swipeableCardFrames,
                    onSwipe: { forward in stepTool(forward: forward) }
                ))
            headerBar
        }
        .background(Theme.paper)
        // The CalendarWidgetExtension deep-links here (rystools://calendar) to jump
        // straight to Calendar instead of whatever tab happened to be open.
        .onChange(of: router.pendingTool) { _, tool in
            guard let tool else { return }
            selectedTool = tool
            router.pendingTool = nil
        }
        // An expanded search field showing a DIFFERENT tool's text after switching
        // via the nav menu would be confusing — each tool's own search text is still
        // preserved for next time, just not left visibly expanded.
        .onChange(of: selectedTool) {
            isSearchExpanded = false
            isSearchFieldFocused = false
        }
        .sheet(item: $composePrefill) { prefill in
            ComposeMailView(prefill: prefill, service: GmailService(auth: auth))
        }
        // Attached at the root, not inside headerBar, so this always paints above
        // `content` regardless of view-tree paint order — a Menu's system popup gets
        // this for free, a custom dropdown has to ask for it explicitly.
        .overlay {
            if isNavMenuOpen {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture { isNavMenuOpen = false }
                    navMenuPanel
                        .padding(.top, headerHeight + 8)
                }
            }
        }
    }

    // Flat content-swapping under one header, matching the web app — no push/pop
    // navigation chrome needed now that Email's search field lives in the header
    // itself instead of docking into a navigation bar via .searchable.
    @ViewBuilder
    private var content: some View {
        switch selectedTool {
        case .email: EmailView(searchText: $emailSearchText, folder: $selectedFolder)
        case .calendar: CalendarView(triggerCreateEvent: $triggerCalendarCreate, searchText: $calendarSearchText)
        case .scratch: ScratchView()
        }
    }

    // Each tool's own search text, kept separate so switching tools (or away and
    // back) doesn't lose what you'd typed in another one. Note has none of its own
    // (see headerBar, which hides the search icon entirely for it).
    private var currentSearchText: Binding<String> {
        switch selectedTool {
        case .email: return $emailSearchText
        case .calendar: return $calendarSearchText
        case .scratch: return .constant("")
        }
    }

    private var searchPlaceholder: String {
        switch selectedTool {
        case .email: return "Search mail"
        case .calendar: return "Search events"
        case .scratch: return ""
        }
    }

    // One row, shown identically for every tool — the nav menu trigger always sits
    // centered; search (Email/Calendar only, expands in place of the row) and the
    // "+" button (Email, signed in; Calendar always; Note never) are the only parts
    // that ever come or go on either side of it, so the trigger never actually
    // moves when switching tools.
    private var headerBar: some View {
        HStack(spacing: 10) {
            if isSearchExpanded {
                searchField
                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSearchExpanded = false
                        isSearchFieldFocused = false
                        currentSearchText.wrappedValue = ""
                    }
                }
                .font(Theme.Font.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            } else {
                // Just the icon by default — tapping expands it into the full search
                // field, in place of the rest of this row. Note has no search of its
                // own (see currentSearchText/searchPlaceholder), so this is hidden
                // entirely there rather than expanding into a field that does nothing.
                if selectedTool != .scratch {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSearchExpanded = true
                            isSearchFieldFocused = true
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(Theme.Font.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Theme.darkGrey)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
                navMenuTrigger
                Spacer(minLength: 0)

                // One "+" button, in the same spot for every tool that has one —
                // Email's Compose and Calendar's Create Event used to each be their
                // own button (in their own content, below the header); now they're
                // one button here that does whichever one applies to the current
                // tool. Email's still hides when signed out (there's nothing to
                // compose to). Note has no "+" at all — there's only ever the one
                // note, nothing to add.
                if selectedTool == .calendar || (selectedTool == .email && auth.isSignedIn) {
                    Button {
                        switch selectedTool {
                        case .email:
                            composePrefill = ComposePrefill(to: "", subject: "", body: "", threadId: nil)
                        case .calendar:
                            triggerCalendarCreate = true
                        case .scratch:
                            break
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(Theme.Font.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Theme.green)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Opaque now, not the transparent-over-scrolled-content look this started
        // with — content sliding up from below (see RootView.body's ZStack, where
        // content is drawn first and headerBar on top) should disappear behind the
        // header entirely instead of showing through it.
        .background(Theme.paper)
        .alert("Sign-in error", isPresented: Binding(
            get: { auth.lastError != nil },
            set: { if !$0 { auth.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(auth.lastError ?? "")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Font.caption)
                .foregroundStyle(.white)
            TextField(searchPlaceholder, text: currentSearchText)
                .font(Theme.Font.subheadline)
                .foregroundStyle(.white)
                .tint(.white)
                .submitLabel(.search)
                .focused($isSearchFieldFocused)
            if !currentSearchText.wrappedValue.isEmpty {
                Button {
                    currentSearchText.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Theme.darkGrey)
        .clipShape(Capsule())
    }

    // Shared by the content-area background swipe (see BackgroundSwipeDetector) —
    // "forward" means toward the end of Tool.allCases (declaration order), same
    // direction as a leftward swipe. The nav menu is the primary way to switch tools
    // now, but this still works as an extra, undocumented shortcut.
    private func stepTool(forward: Bool) {
        let tools = Tool.allCases
        guard let currentIndex = tools.firstIndex(of: selectedTool) else { return }
        let targetIndex = forward ? currentIndex + 1 : currentIndex - 1
        guard tools.indices.contains(targetIndex) else { return }
        selectedTool = tools[targetIndex]
    }

    // Shows the current context — the selected mail folder while on Email, or the
    // other tool's own name otherwise — since this one menu is both the folder picker
    // and the tool switcher now.
    private var navMenuLabel: String {
        switch selectedTool {
        case .email: return selectedFolder.label
        case .calendar: return Tool.calendar.label
        case .scratch: return Tool.scratch.label
        }
    }

    private var navMenuTrigger: some View {
        Button {
            isNavMenuOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(navMenuLabel)
                    .font(Theme.Font.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(Theme.Font.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isNavMenuOpen ? 180 : 0))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Fixed order per an explicit ask: Inbox, Calendar, Note, Archive, Sign out —
    // everywhere in the app you'd go is one tap from here now that there's no
    // separate tool-switcher bar or Settings screen. Note this drops the "All" mail
    // folder from the menu entirely (it wasn't in the requested order) — flagged in
    // case that was an oversight rather than intentional.
    private var navMenuPanel: some View {
        VStack(alignment: .center, spacing: 0) {
            dropdownRow(title: "Inbox", isSelected: selectedTool == .email && selectedFolder == .inbox) {
                selectedFolder = .inbox
                selectedTool = .email
                isNavMenuOpen = false
            }
            dropdownRow(title: Tool.calendar.label, isSelected: selectedTool == .calendar) {
                selectedTool = .calendar
                isNavMenuOpen = false
            }
            dropdownRow(title: Tool.scratch.label, isSelected: selectedTool == .scratch) {
                selectedTool = .scratch
                isNavMenuOpen = false
            }
            dropdownRow(title: "Archive", isSelected: selectedTool == .email && selectedFolder == .archive) {
                selectedFolder = .archive
                selectedTool = .email
                isNavMenuOpen = false
            }
            if auth.isSignedIn, let email = auth.userEmail {
                dropdownRow(title: "Sign out \(email)", tintColor: Theme.expense) {
                    auth.signOut()
                    isNavMenuOpen = false
                }
            } else {
                dropdownRow(title: "Sign In") {
                    auth.signIn()
                    isNavMenuOpen = false
                }
            }
        }
        // Without this, the VStack expands to whatever width the enclosing
        // full-screen overlay proposes (the whole screen) instead of hugging its
        // own content — each row's own maxWidth: .infinity (see dropdownRow) then
        // exists only to match the widest row, not to fill the screen.
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 220, alignment: .center)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.darkGrey, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }

    private func dropdownRow(
        title: String,
        isSelected: Bool = false,
        tintColor: Color = Theme.ink,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.subheadline.weight(isSelected ? .bold : .regular))
                .lineLimit(1)
                .foregroundStyle(tintColor)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(isSelected ? Theme.goldBg : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
