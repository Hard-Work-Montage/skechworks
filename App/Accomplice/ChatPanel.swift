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

    var body: some View {
        // The session belongs to the document, so it survives the panel being hidden.
        ChatPanelBody(session: store.chat)
    }
}

private struct ChatPanelBody: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: ChatSession

    @AppStorage("ai.backend") private var backend = ModelConnector.Backend.ollama.rawValue
    @AppStorage("ai.ollamaHost") private var ollamaHost = "http://127.0.0.1:11434"
    @AppStorage("ai.model") private var model = LocalModel.recommended
    @AppStorage("ai.openRouterModel") private var openRouterModel = "anthropic/claude-sonnet-4.5"
    @AppStorage("ai.accompliceHost") private var accompliceHost = "https://accomplice.ai"

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var settings: ModelConnector.Settings {
        var s = ModelConnector.Settings()
        s.backend = ModelConnector.Backend(rawValue: backend) ?? .ollama
        s.ollamaHost = ollamaHost
        s.model = model
        s.openRouterModel = openRouterModel
        s.accompliceHost = accompliceHost
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

    @ViewBuilder
    private var transcript: some View {
        // The empty state sits outside the scroll view. Inside it, "fill the height"
        // means nothing — a scroll view's content is as tall as its content — so the
        // placeholder was pinned to the top however it was centred.
        if session.messages.isEmpty {
            placeholder
        } else {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
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
    }

    /// An invitation, not a label. One is drawn per panel appearance — stable across
    /// re-renders so it doesn't flicker mid-thought, but a fresh face each session.
    private static let blankDocOpeners = [
        "Where should we start?",
        "What are we making?",
        "Blank page. Big plans?",
        "Describe it, or just start drawing.",
        "What's the idea?",
    ]
    private static let workingOpeners = [
        "What's next?",
        "What should we change?",
        "Want to tweak something?",
        "Point me at something.",
        "What needs work?",
    ]
    @State private var openerSeed = Int.random(in: 0..<1_000)

    /// Centred, like "No selection" in the inspector above it — the two empty states
    /// sit in the same column and should read as the same kind of thing.
    private var placeholder: some View {
        // A document with nothing on any page gets the fresh-start voice; anything
        // else gets the mid-work one. Checked live, so drawing the first shape flips
        // the question from "where do we begin" to "what now".
        let blank = store.page.map { $0.layers.isEmpty } ?? true
        let pool = blank ? Self.blankDocOpeners : Self.workingOpeners
        return VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(pool[openerSeed % pool.count])
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask…", text: $draft, axis: .vertical)
                .accessibilityIdentifier("chat-input")
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
