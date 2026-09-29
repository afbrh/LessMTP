import SwiftUI
import UIKit
import WidgetKit

// POC scope note: the web app's "type three blank lines to split into a new box, tap
// Backspace at position 0 to merge" gesture isn't replicated here — this shows/edits
// the same boxes (still saved as one string joined by "\n\n\n", so it stays compatible
// with scratch.html) via an explicit "+" button instead, which is far less code for a
// first pass and still proves out the real load/save round-trip to Drive.
@MainActor
final class ScratchViewModel: ObservableObject {
    @Published var sections: [String] = [""]
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var saveStatus: String = ""

    private var saveTask: Task<Void, Never>?

    func load(store: DriveStore) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let tools = try await store.loadTools()
            let text = tools.object("scratch").string("text") ?? ""
            sections = text.isEmpty ? [""] : text.components(separatedBy: "\n\n\n")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func queueSave(store: DriveStore) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await save(store: store)
        }
    }

    private func save(store: DriveStore) async {
        saveStatus = "Saving…"
        do {
            try await store.save(tool: "scratch", data: ["text": sections.joined(separator: "\n\n\n")])
            saveStatus = "Saved"
            // The medium widget shows the top box's live text — without this it'd only
            // catch up on its own ~30 min timeline refresh.
            WidgetCenter.shared.reloadTimelines(ofKind: "CalendarWidget")
        } catch {
            saveStatus = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func addSection() {
        sections.append("")
    }
}

private struct RowFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// The long-press-then-drag reorder gesture, as a single real UILongPressGestureRecognizer
// attached to the window — not SwiftUI's own LongPressGesture(...).sequenced(before:
// DragGesture(...)) attached per-row, and not a per-row UIViewRepresentable either.
// Both of those were tried first:
//   - SwiftUI's own gesture, even via .simultaneousGesture, was silently blocking the
//     row's native .swipeActions delete gesture from ever recognizing at all (swiping
//     did nothing, every time, in every card color).
//   - A per-row UIViewRepresentable with its own local UILongPressGestureRecognizer
//     fixed swiping, but broke reordering: attached via .background(), that
//     recognizer's view sits BEHIND the row's own content (the TextEditor) in normal
//     UIKit hit-testing, so it only ever received touches when nothing was on top of
//     it to claim them first — which in practice was never.
// A single window-level recognizer (same technique as BackgroundSwipeDetector) sees
// every touch regardless of what's on top, and figures out which row (if any) a touch
// belongs to itself, from the already-tracked rowFrames (see RowFrameKey — now in
// .global coordinates to match window-space touch locations, not the List's own
// former "scratchBoxes" named space).
private struct ScratchReorderGesture: UIViewRepresentable {
    var rowFrames: [Int: CGRect]  // in .global/window coordinates
    var onChanged: (Int, CGSize) -> Void  // (row index the press started on, translation since)
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.rowFrames = rowFrames
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.attach(to: uiView)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var rowFrames: [Int: CGRect] = [:]
        var onChanged: (Int, CGSize) -> Void
        var onEnded: () -> Void
        private weak var attachedWindow: UIWindow?
        private var activeIndex: Int?
        private var startLocation: CGPoint?

        init(onChanged: @escaping (Int, CGSize) -> Void, onEnded: @escaping () -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func attach(to view: UIView) {
            guard let window = view.window, attachedWindow !== window else { return }
            attachedWindow = window
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.minimumPressDuration = 0.35
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            window.addGestureRecognizer(recognizer)
        }

        @objc private func handle(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                let location = recognizer.location(in: nil)
                guard let index = rowFrames.first(where: { $0.value.contains(location) })?.key else { return }
                activeIndex = index
                startLocation = location
            case .changed:
                guard let index = activeIndex, let start = startLocation else { return }
                let current = recognizer.location(in: nil)
                onChanged(index, CGSize(width: current.x - start.x, height: current.y - start.y))
            case .ended, .cancelled, .failed:
                activeIndex = nil
                startLocation = nil
                onEnded()
            default:
                break
            }
        }

        // Never block anything else — List scrolling, the row's own native
        // .swipeActions gesture, TextEditor's tap-to-place-cursor — this only ever
        // observes, same reasoning as BackgroundSwipeDetector's identical override.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        // Only ever engage for a touch that actually starts on a row — leaves List
        // scrolling, swipeActions, the Add-box button, and empty space untouched.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let location = touch.location(in: nil)
            return rowFrames.contains { $0.value.contains(location) }
        }
    }
}

private struct ContainerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 300
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ScratchView: View {
    @EnvironmentObject var auth: GoogleAuthService
    @EnvironmentObject var appSettings: AppSettings
    // Set by RootView's header "+" button (now in line with the nav dropdown, instead
    // of a button living in this screen's own content) — flipped back to false
    // immediately after triggering, so it can fire again next tap.
    @Binding var triggerAddBox: Bool
    // Owned by RootView's header search field (same pattern as EmailView's own
    // searchText) — boxes not containing this text are hidden entirely (see
    // filteredIndices), rather than just dimmed or scrolled past.
    @Binding var searchText: String
    @StateObject private var viewModel = ScratchViewModel()

    // Hand-rolled drag-to-reorder (rather than List's edit-mode or the Drag & Drop
    // framework's .onDrag) so a long hold-and-move on a box reorders it while a quick
    // tap still goes straight through to the TextEditor to place the cursor — neither
    // of the built-in mechanisms could do that without either a visible reorder handle
    // icon or fighting the text editor's own tap recognizer.
    @State private var rowFrames: [Int: CGRect] = [:]
    @State private var draggingIndex: Int?
    @State private var dragStartFrame: CGRect?
    @State private var dragTranslation: CGSize = .zero
    // The available width for a box's own content, measured live so each box's height
    // can be computed to fit all of its text instead of scrolling internally.
    @State private var containerWidth: CGFloat = 300
    @FocusState private var focusedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // maxWidth/maxHeight: .infinity here is what was actually behind the "flash
            // in the middle of the screen" — a List (the else branch below) always
            // fills available space on its own, but a bare ProgressView/Text doesn't,
            // so without this, the whole view would shrink to fit just the tiny loading
            // spinner during that state and get re-centered by whatever hosts RootView,
            // then snap back to full-screen once the List appeared. Forcing this Group
            // to always fill the screen, loading or not, means switching to Scratch
            // never collapses and re-expands — same as every other tool, which all
            // happen to keep their own loading state inside an always-full-size
            // container already (e.g. Email's spinner is a row inside its
            // always-present List).
            Group {
                if viewModel.isLoading {
                    ProgressView().padding(.top, 40)
                } else if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(Theme.inkSoft).padding(.top, 20)
            } else if isSearching && filteredIndices.isEmpty {
                Text("No matching notes.").foregroundStyle(Theme.inkSoft).padding(.top, 20)
            } else {
                // A real List (not a plain ScrollView) specifically so the delete
                // action can be a native .swipeActions button — the same one Email and
                // Calendar use — instead of a hand-rolled swipe gesture.
                List {
                    // Real indices into viewModel.sections, not a filtered copy of the
                    // array itself — boxEditor/deleteSection/the reorder gesture all
                    // already work by index into the real array, so a non-matching box
                    // just never appears here rather than needing any of that logic to
                    // change.
                    ForEach(filteredIndices, id: \.self) { index in
                        boxEditor(index)
                            // Reports this row's frame to BackgroundSwipeDetector (tool
                            // switching) and ScratchReorderGesture (drag-to-reorder) —
                            // .global so it lines up with both's window-space touch math.
                            .swipeableCard()
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: RowFrameKey.self,
                                        value: [index: proxy.frame(in: .global)]
                                    )
                                }
                            )
                            .zIndex(draggingIndex == index ? 1 : 0)
                            .opacity(draggingIndex == index ? 0.9 : 1)
                            .offset(y: dragOffset(for: index))
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteSection(index)
                                } label: {
                                    Text("Delete")
                                        .font(Theme.Font.subheadline.weight(.bold))
                                        .foregroundStyle(Theme.expense)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(Theme.expense, lineWidth: 1.5)
                                        )
                                }
                                .tint(Theme.paper)
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContainerWidthKey.self, value: proxy.size.width)
                    }
                )
                .onPreferenceChange(ContainerWidthKey.self) { containerWidth = $0 }
                // One shared reorder gesture for the whole list — see
                // ScratchReorderGesture for why this replaced a per-row attachment.
                .background(
                    ScratchReorderGesture(
                        rowFrames: rowFrames,
                        onChanged: { index, translation in handleDragChanged(index: index, translation: translation) },
                        onEnded: { endDrag() }
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.paper)
        // The keyboard-dismiss "Done" button used to be a .toolbar(placement: .keyboard)
        // accessory — moved here because this app deliberately has no NavigationStack
        // anywhere outside of sheets (see RootView), and ScratchView was the only
        // top-level tool screen using .toolbar at all. That mismatch (a toolbar with no
        // navigation host to actually attach to) was producing a black flash every
        // single time this view appeared, instead of switching to it cleanly like every
        // other tool. A plain safeAreaInset button rides above the keyboard the same
        // way (SwiftUI's default keyboard avoidance still applies), without needing any
        // toolbar/navigation infrastructure at all.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if focusedIndex != nil {
                    HStack {
                        Spacer()
                        Button("Done") { focusedIndex = nil }
                            .font(Theme.Font.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.gold)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.darkGrey)
                }
                if !viewModel.saveStatus.isEmpty {
                    Text(viewModel.saveStatus)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.inkSoft)
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(Theme.paper)
                }
            }
        }
        .task { await reload() }
        .onChange(of: auth.isSignedIn) { Task { await reload() } }
        .onChange(of: triggerAddBox) { _, newValue in
            guard newValue else { return }
            viewModel.addSection()
            triggerAddBox = false
        }
    }

    private func reload() async {
        guard auth.isSignedIn else { return }
        await viewModel.load(store: .shared)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Indices (into viewModel.sections) of boxes whose text contains the search
    // query — every index, in order, when not searching.
    private var filteredIndices: [Int] {
        guard isSearching else { return Array(viewModel.sections.indices) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewModel.sections.indices.filter { viewModel.sections[$0].lowercased().contains(query) }
    }

    // The dragged box's own layout slot moves whenever it swaps position with another
    // box, so its offset has to be corrected each time: distance from the touch's
    // fixed starting frame to wherever this box currently sits, not just the raw
    // gesture translation (which alone would make it jump on every swap).
    private func dragOffset(for index: Int) -> CGFloat {
        guard draggingIndex == index, let dragStartFrame, let currentFrame = rowFrames[index] else { return 0 }
        let targetMidY = dragStartFrame.midY + dragTranslation.height
        return targetMidY - currentFrame.midY
    }

    private func handleDragChanged(index: Int, translation: CGSize) {
        if draggingIndex == nil {
            draggingIndex = index
            dragStartFrame = rowFrames[index]
        }
        dragTranslation = translation
        guard let draggingIndex, let dragStartFrame else { return }
        let liveMidY = dragStartFrame.midY + translation.height
        if let target = rowFrames.first(where: { key, frame in
            key != draggingIndex && frame.minY <= liveMidY && liveMidY <= frame.maxY
        })?.key {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                viewModel.sections.move(
                    fromOffsets: IndexSet(integer: draggingIndex),
                    toOffset: target > draggingIndex ? target + 1 : target
                )
            }
            self.draggingIndex = target
        }
    }

    private func endDrag() {
        if draggingIndex != nil {
            viewModel.queueSave(store: .shared)
        }
        draggingIndex = nil
        dragStartFrame = nil
        dragTranslation = .zero
    }

    // Removing by index rather than value, so two identical (e.g. both blank) boxes
    // don't risk deleting the wrong one — always keeps at least one box, same as a
    // freshly loaded empty scratchpad.
    private func deleteSection(_ index: Int) {
        guard viewModel.sections.indices.contains(index) else { return }
        viewModel.sections.remove(at: index)
        if viewModel.sections.isEmpty { viewModel.sections = [""] }
        rowFrames = [:]
        viewModel.queueSave(store: .shared)
    }

    private func boxEditor(_ index: Int) -> some View {
        // Bounds-checked rather than a bare subscript — TextEditor's UITextView can
        // still fire this Binding's get/set for a row that's mid-teardown right after
        // deleteSection shrinks the array (the crash this caused twice), since that
        // UIKit-side callback isn't perfectly synchronous with SwiftUI's own re-render.
        TextEditor(text: Binding(
            get: { viewModel.sections.indices.contains(index) ? viewModel.sections[index] : "" },
            set: { newValue in
                guard viewModel.sections.indices.contains(index) else { return }
                viewModel.sections[index] = newValue
                viewModel.queueSave(store: .shared)
            }
        ))
        .focused($focusedIndex, equals: index)
        .frame(height: estimatedHeight(
            for: viewModel.sections.indices.contains(index) ? viewModel.sections[index] : "",
            width: containerWidth
        ))
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .font(Theme.Font.custom(size: 16))
        .foregroundStyle(LightBoxTheme.ink)
        .padding(12)
        .background(LightBoxTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(LightBoxTheme.cardBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // No max height/internal scrolling any more — every box grows to fit all of its
    // own text. Deliberately under-estimates the usable width (rather than measuring
    // cardStyle's padding and TextEditor's own text-container insets exactly) so any
    // rounding error makes the box a little taller, never short enough to clip text.
    private func estimatedHeight(for text: String, width: CGFloat) -> CGFloat {
        // width is now the List's own full-bleed width (boxEditor's horizontal padding
        // isn't baked into it the way the old ScrollView's outer padding was), so this
        // subtracts that padding (32) too, on top of the card's own 24 and the usual
        // safety buffer.
        let usableWidth = max(50, width - 64)
        // Match whatever font is actually rendering the text (see the "look and feel"
        // font setting) — measuring with the system font while displaying a different,
        // wider/taller one could under-measure and clip the last line.
        let font = AppSettings.shared.font.familyName.flatMap { UIFont(name: $0, size: 16) }
            ?? UIFont.systemFont(ofSize: 16)
        let measured = (text.isEmpty ? " " : text) as NSString
        let bounding = measured.boundingRect(
            with: CGSize(width: usableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return max(60, ceil(bounding.height) + 24)
    }
}
