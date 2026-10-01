import SwiftUI

// A single-purpose email client now — Calendar and Note were removed entirely per an
// explicit ask ("I want this to be purely an email app"). No tool switching, no
// NavigationStack at this level either (EmailView owns its own, for its push-to-detail
// screen) — just Email's list under one fixed header, with a dropdown for the mail
// folder and sign-in/out.
struct RootView: View {
    @EnvironmentObject var auth: GoogleAuthService
    @EnvironmentObject var appSettings: AppSettings
    @State private var emailSearchText = ""
    @State private var selectedFolder: MailFolder = .inbox
    @State private var isNavMenuOpen = false
    @State private var isSearchExpanded = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var composePrefill: ComposePrefill?

    // The header floats over the content instead of sitting in its own row (it has its
    // own opaque background — see headerBar — so scrolled content disappears behind
    // it rather than showing through).
    //
    // static (not private) because EmailView's own List needs the same number: its
    // NavigationStack (for the push-to-detail screen) doesn't reliably inherit this
    // safeAreaInset from here once its own navigation bar is hidden, which was
    // letting the top row scroll up partly behind the header — see EmailView's own
    // explicit top inset that reuses this exact value.
    static let headerHeight: CGFloat = 64

    var body: some View {
        ZStack(alignment: .top) {
            EmailView(searchText: $emailSearchText, folder: $selectedFolder)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: Self.headerHeight)
                }
            headerBar
        }
        .background(Theme.paper)
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
                        .padding(.top, Self.headerHeight + 8)
                }
            }
        }
    }

    // Back to one top row: a search button, the centered nav menu trigger, and the
    // compose button — search expands in place (replacing the whole row with a field
    // + Cancel) when tapped, rather than living as its own persistent bottom bar.
    private var headerBar: some View {
        Group {
            if isSearchExpanded {
                expandedSearchRow
            } else {
                HStack {
                    searchButton
                    Spacer(minLength: 0)
                    navMenuTrigger
                    Spacer(minLength: 0)
                    if auth.isSignedIn {
                        composeButton
                    } else {
                        // Keeps the nav trigger centered even while signed out, by
                        // balancing the leading search button's width.
                        Color.clear.frame(width: 36, height: 36)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Opaque so content scrolling up from below (see RootView.body's ZStack,
        // where content is drawn first and headerBar on top) disappears behind the
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

    private var searchButton: some View {
        Button {
            isSearchExpanded = true
            isSearchFieldFocused = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(Theme.Font.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var composeButton: some View {
        Button {
            composePrefill = ComposePrefill(to: "", subject: "", body: "", threadId: nil)
        } label: {
            Image(systemName: "square.and.pencil")
                .font(Theme.Font.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(Color.black)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var expandedSearchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(Theme.Font.subheadline)
                    .foregroundStyle(.white)
                TextField("Search mail", text: $emailSearchText)
                    .font(Theme.Font.subheadline)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .submitLabel(.search)
                    .focused($isSearchFieldFocused)
                if !emailSearchText.isEmpty {
                    Button {
                        emailSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Theme.Font.subheadline)
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.darkGrey)
            .clipShape(Capsule())

            Button("Cancel") {
                isSearchFieldFocused = false
                isSearchExpanded = false
                emailSearchText = ""
            }
            .font(Theme.Font.subheadline)
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
    }

    private var navMenuTrigger: some View {
        Button {
            isNavMenuOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(selectedFolder.label)
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

    // Mail folder picker plus sign-in/out — the one place to switch folders or
    // account state now that there's nothing else in the app to navigate to.
    private var navMenuPanel: some View {
        VStack(alignment: .center, spacing: 0) {
            dropdownRow(title: "Inbox", isSelected: selectedFolder == .inbox) {
                selectedFolder = .inbox
                isNavMenuOpen = false
            }
            dropdownRow(title: "Archive", isSelected: selectedFolder == .archive) {
                selectedFolder = .archive
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
