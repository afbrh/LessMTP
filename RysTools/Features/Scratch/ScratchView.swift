import SwiftUI
import WidgetKit

// Exactly one persistent note, not a list of separately addable/reorderable boxes —
// per an explicit ask to simplify this down from the earlier multi-box design (which
// used to support adding, deleting, reordering, and searching individual boxes). Still
// saved under the same "scratch"/"text" key in Drive as before, so this stays
// compatible with scratch.html and with whatever the widget reads — just without this
// app's own former "\n\n\n"-joined multi-box splitting on top of it.
@MainActor
final class ScratchViewModel: ObservableObject {
    @Published var text: String = ""
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
            text = tools.object("scratch").string("text") ?? ""
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
            try await store.save(tool: "scratch", data: ["text": text])
            saveStatus = "Saved"
            // The widget shows this note's live text — without this it'd only catch
            // up on its own ~30 min timeline refresh.
            WidgetCenter.shared.reloadTimelines(ofKind: "CalendarWidget")
        } catch {
            saveStatus = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

struct ScratchView: View {
    @EnvironmentObject var auth: GoogleAuthService
    @StateObject private var viewModel = ScratchViewModel()
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 40)
            } else if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(Theme.inkSoft)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 20)
            } else {
                TextEditor(text: Binding(
                    get: { viewModel.text },
                    set: { newValue in
                        viewModel.text = newValue
                        viewModel.queueSave(store: .shared)
                    }
                ))
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .font(Theme.Font.custom(size: 16))
                .foregroundStyle(LightBoxTheme.ink)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Theme.paper)
        // A plain safeAreaInset button rides above the keyboard without needing any
        // toolbar/navigation infrastructure — see the app-wide note on why this
        // avoids .toolbar(placement: .keyboard) (RootView has no NavigationStack
        // outside of sheets).
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if isFocused {
                    HStack {
                        Spacer()
                        Button("Done") { isFocused = false }
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
    }

    private func reload() async {
        guard auth.isSignedIn else { return }
        await viewModel.load(store: .shared)
    }
}
