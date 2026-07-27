import AccompliceCore
import SwiftUI

/// A conversation, not a form.
///
/// Edits apply as they're proposed — undo is one keystroke and gating every recolour
/// behind a confirm button makes a tool feel like it doesn't trust you. What still
/// stops to ask is the narrow case undo alone doesn't make comfortable: destroying
/// things, or touching far more than one sentence should.
///
/// Keeping the conversation matters as much as the acting. When a request comes back
/// wrong the fix is usually one more sentence of context, and a one-shot command bar
/// throws that away every time.
struct ChatPanel: View {
    @EnvironmentObject var store: DocumentStore
    @StateObject private var session = ChatSession()

    @AppStorage("ai.backend") private var backend = ModelConnector.Backend.ollama.rawValue
    @AppStorage("ai.ollamaHost") private var ollamaHost = "http://127.0.0.1:11434"
    @AppStorage("ai.model") private var model = "qwen3-coder:30b"
    @AppStorage("ai.openRouterKey") private var openRouterKey = ""
    @AppStorage("ai.openRouterModel") private var openRouterModel = "anthropic/claude-sonnet-4.5"

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var settings: ModelConnector.Settings {
        var s = ModelConnector.Settings()
        s.backend = ModelConnector.Backend(rawValue: backend) ?? .ollama
        s.ollamaHost = ollamaHost
        s.model = model
        s.openRouterKey = openRouterKey
        s.openRouterModel = openRouterModel
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            Text(settings.backend == .ollama ? model : openRouterModel)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if session.busy { ProgressView().controlSize(.small) }
            Button {
                session.messages.removeAll()
            } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear conversation")
                .disabled(session.messages.isEmpty)
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if session.messages.isEmpty { placeholder }
                    ForEach(session.messages) { m in
                        MessageRow(message: m) { pending in
                            session.confirm(pending, store: store)
                        }
                        .id(m.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: session.messages.count) { _, _ in
                if let last = session.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask for changes to this document.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(["Rename every artboard to coin-{i}",
                     "Delete any path narrower than 4",
                     "Make the black shapes 50% opacity",
                     "Which layers overflow their artboard?"], id: \.self) { example in
                Button(example) { draft = example; send() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
            Button {
                send()
            } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || session.busy)
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !session.busy else { return }
        draft = ""
        session.send(text, store: store, settings: settings)
    }
}

// MARK: - Transcript rows

private struct MessageRow: View {
    let message: ChatMessage
    let onConfirm: (ChatMessage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message.role {
            case .user:
                Text(message.text)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, alignment: .trailing)

            case .assistant:
                if !message.text.isEmpty {
                    Text(message.text).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !message.applied.isEmpty {
                    // What it actually did, after the fact — undo is right there, but
                    // you should never have to guess what changed.
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(message.applied.enumerated()), id: \.offset) { _, line in
                            Label(line, systemImage: "checkmark")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if message.nothingHappened {
                    Label("No changes were made", systemImage: "circle.slash")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(Array(message.problems.enumerated()), id: \.offset) { _, p in
                    Label(p, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if message.awaitingConfirmation {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(message.confirmPrompt, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                        HStack {
                            Button("Do it") { onConfirm(message) }
                                .keyboardShortcut(.defaultAction)
                            Button("Skip") { onConfirm(message.declined) }
                        }
                    }
                    .padding(8)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

            case .error:
                Label(message.text, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }
}
