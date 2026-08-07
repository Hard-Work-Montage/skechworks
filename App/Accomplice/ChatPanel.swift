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

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var settings: ModelConnector.Settings {
        var s = ModelConnector.Settings()
        s.backend = ModelConnector.Backend(rawValue: backend) ?? .ollama
        s.ollamaHost = ollamaHost
        s.model = model
        s.openRouterModel = openRouterModel
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
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
                        MessageRow(message: m,
                                   onStop: session.canStop ? { session.stop() } : nil) { pending in
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
            // A running tool grows the entry it already added, so the count never
            // changes and the view above would sit still while the log ran off
            // the bottom.
            .onChange(of: session.messages.last?.steps.count ?? 0) { _, _ in
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

/// Accomplice's face in the transcript, in whatever colourway the app icon is
/// wearing — so the assistant looks like the app rather than like a generic
/// sparkle.
private struct Avatar: View {
    @AppStorage("appIconTheme") private var theme = AppIconTheme.gradient.rawValue

    var body: some View {
        Group {
            if let image = AppIconTheme(rawValue: theme)?.thumbnail(points: 20) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "sparkles").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    /// Present only while something is actually running and stoppable.
    var onStop: (() -> Void)?
    let onConfirm: (ChatMessage) -> Void
    /// Working notes start open while the tool runs and fold away once it's
    /// done — you want to watch them live and almost never afterwards, but
    /// "almost never" is why they're kept rather than thrown away.
    @State private var showSteps: Bool?
    /// The list of what was made. Folded to start: it describes something that
    /// is already sitting on the canvas in front of you.
    @State private var showApplied = false

    /// Open while it runs, folded once it stops, and either way the person can
    /// say otherwise.
    private var stepsVisible: Bool { showSteps ?? message.running }

    /// A list that folds away behind a one-line summary. Both the running
    /// commentary and the list of what was made are asides — worth having,
    /// almost never worth reading twice — and a column of them pushes the thing
    /// you DID want to read off the top of the panel.
    private func folded(_ lines: [String], title: String, summary: String,
                        open: Bool, toggle: @escaping () -> Void,
                        symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: toggle) {
                HStack(spacing: 3) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(open ? title : summary)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)

            if open {
                HStack(alignment: .top, spacing: 7) {
                    Rectangle().fill(.quaternary).frame(width: 1)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Group {
                                if let symbol {
                                    Label(line, systemImage: symbol)
                                } else {
                                    Text(line)
                                }
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private var stepLog: some View {
        folded(message.steps,
               title: "Working notes",
               summary: "\(message.steps.count) working notes",
               open: stepsVisible,
               toggle: { withAnimation(.easeOut(duration: 0.15)) { showSteps = !stepsVisible } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message.role {
            case .user:
                Text(message.text)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, alignment: .trailing)

            case .assistant:
                HStack(alignment: .top, spacing: 8) {
                    if message.running {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                            .frame(width: 20, height: 20)
                    } else {
                        Avatar()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if !message.text.isEmpty {
                                Text(message.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Spacer(minLength: 0)
                            }
                            // A run can be minutes long and can hang on something
                            // out of our hands. Waiting is a choice; being unable
                            // to stop waiting isn't.
                            if message.running, let onStop {
                                Button("Stop", action: onStop)
                                    .buttonStyle(.plain)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !message.steps.isEmpty { stepLog }
                    }
                }
                if !message.applied.isEmpty {
                    // What it actually did, after the fact — undo is right there, but
                    // you should never have to guess what changed. Folded, because
                    // by the time you read it the thing is already on the canvas.
                    folded(message.applied,
                           title: message.appliedNoun.capitalized,
                           summary: "\(message.applied.count) \(message.appliedNoun)",
                           open: showApplied,
                           toggle: { withAnimation(.easeOut(duration: 0.15)) { showApplied.toggle() } },
                           symbol: "checkmark")
                }
                if let offer = message.offer {
                    // Its own button, not the confirm bar above: that one is
                    // about undoing a big edit, this one is about spending.
                    Button(offer.label) { offer.run() }
                        .controlSize(.small)
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
