import SwiftUI

// Prefilled data for a Reply or Forward — presented as a sheet item so opening a new
// compose always starts from a fresh, correctly-prefilled state (no stale leftover
// text from whatever was last open).
struct ComposePrefill: Identifiable {
    let id = UUID()
    var to: String
    var subject: String
    var body: String
    var threadId: String?
}

// Matches email.html's compose overlay (To/Subject/Body, Send) — a threadId sends as a
// reply within that conversation, nil starts a new one (used for both Forward, which
// intentionally goes to someone new, and a message with no thread at all).
struct ComposeMailView: View {
    let prefill: ComposePrefill
    let service: GmailService
    var onSent: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var to: String
    @State private var subject: String
    @State private var messageBody: String
    @State private var isSending = false
    @State private var errorMessage: String?

    init(prefill: ComposePrefill, service: GmailService, onSent: (() -> Void)? = nil) {
        self.prefill = prefill
        self.service = service
        self.onSent = onSent
        _to = State(initialValue: prefill.to)
        _subject = State(initialValue: prefill.subject)
        _messageBody = State(initialValue: prefill.body)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field(label: "To") {
                        TextField("recipient@example.com", text: $to)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    field(label: "Subject") {
                        TextField("Subject", text: $subject)
                    }
                    field(label: "Message") {
                        TextEditor(text: $messageBody)
                            .frame(minHeight: 220)
                            .scrollContentBackground(.hidden)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.Font.footnote)
                            .foregroundStyle(Theme.expense)
                    }
                }
                .padding(20)
            }
            .background(Theme.paper)
            .navigationTitle(prefill.threadId != nil ? "Reply" : "New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await send() } }
                            .disabled(to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func send() async {
        isSending = true
        errorMessage = nil
        do {
            try await service.sendMessage(
                to: to.trimmingCharacters(in: .whitespacesAndNewlines),
                subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                body: messageBody,
                threadId: prefill.threadId
            )
            onSent?()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSending = false
        }
    }

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.inkSoft)
            content()
                .font(Theme.Font.subheadline)
                .foregroundStyle(Theme.ink)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.paperLine, lineWidth: 1)
                )
        }
    }
}
