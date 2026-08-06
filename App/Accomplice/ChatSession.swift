import AccompliceCore
import Foundation
import SwiftUI

enum ChatRole { case user, assistant, error }

struct ChatMessage: Identifiable {
    let id = UUID()
    var role: ChatRole
    var text: String
    /// One line per command that ran, so what changed is never a guess.
    var applied: [String] = []
    /// Held back pending a yes — only for the destructive-or-huge case.
    var pending: [DocumentCommand] = []
    /// Commands that arrived but couldn't be read.
    var problems: [String] = []
    /// The model spoke but nothing ran. Shown, never hidden.
    var nothingHappened = false
    var confirmPrompt = ""
    var awaitingConfirmation = false

    /// A tool working, rather than something said. Shows a spinner while it runs
    /// and keeps its log afterwards, which is the point: the canvas status line
    /// said one thing at a time and then took it away, so how a drawing got
    /// where it got was gone by the time you wanted to know.
    var activity = false
    var running = false
    /// One line per step, oldest first. Kept after the run.
    var steps: [String] = []

    var declined: ChatMessage {
        var m = self
        m.pending = []
        m.awaitingConfirmation = false
        m.applied = ["Skipped"]
        return m
    }
}

/// Runs the conversation and applies what comes back.
@MainActor
final class ChatSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var busy = false

    /// The running conversation, so a follow-up like "no, the other ones" works.
    private var history: [(role: String, content: String)] = []

    // MARK: - Tools reporting into the transcript

    /// What to call if the person asks the running tool to stop. Set by whoever
    /// opened the activity, cleared when it ends — so the button is only there
    /// while there's something to stop.
    private var stopHandler: (() -> Void)?

    var canStop: Bool { stopHandler != nil }

    func stop() {
        stopHandler?()
        stopHandler = nil
    }

    /// Opens a live entry for a tool that takes a while. Returns its id, which is
    /// how the tool addresses it for the rest of the run.
    func beginActivity(_ title: String, onStop: (() -> Void)? = nil) -> UUID {
        stopHandler = onStop
        // Reporting into a panel that is closed is the same as not reporting, and
        // this is now the only place the run is described. Same key ContentView
        // binds its toggle to, so the panel opens.
        UserDefaults.standard.set(true, forKey: "showChat")
        var m = ChatMessage(role: .assistant, text: title)
        m.activity = true
        m.running = true
        messages.append(m)
        return m.id
    }

    /// Adds a line to a running entry. Repeats of the same line are dropped —
    /// a pass that reports the same thing twice shouldn't grow the log.
    func note(_ id: UUID, _ line: String) {
        guard let i = messages.firstIndex(where: { $0.id == id }), !line.isEmpty else { return }
        guard messages[i].steps.last != line else { return }
        messages[i].steps.append(line)
    }

    /// Closes it out. The spinner stops and the log stays.
    func endActivity(_ id: UUID, text: String, applied: [String] = [], failed: Bool = false) {
        stopHandler = nil
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].running = false
        messages[i].text = text
        messages[i].applied = applied
        if failed { messages[i].role = .error }
    }

    func send(_ text: String, store: DocumentStore, settings: ModelConnector.Settings) {
        messages.append(ChatMessage(role: .user, text: text))
        busy = true

        let document = store.describeDocument()
        let connector = ModelConnector(settings: settings)
        let priorTurns = history

        Task { @MainActor in
            do {
                let turn = try await connector.converse(request: text,
                                                        document: document,
                                                        history: priorTurns)
                history.append((role: "user", content: text))
                history.append((role: "assistant", content: turn.raw))
                trimHistory()

                var reply = ChatMessage(role: .assistant, text: turn.turn.say)
                reply.problems = turn.turn.problems
                if turn.turn.commands.isEmpty {
                    // Talking, not doing. Say so plainly: a model will happily report
                    // "Changed all the black fills" having sent nothing, and letting
                    // that stand unchallenged is worse than any wrong edit — you'd
                    // never know to check.
                    if reply.text.isEmpty { reply.text = "I couldn't turn that into an edit." }
                    reply.nothingHappened = true
                    messages.append(reply)
                } else {
                    let affected = store.countAffected(turn.turn.commands)
                    if turn.turn.needsConfirmation(affecting: affected) {
                        reply.pending = turn.turn.commands
                        reply.awaitingConfirmation = true
                        reply.confirmPrompt = "This affects \(affected) layers. Go ahead?"
                        messages.append(reply)
                    } else {
                        reply.applied = apply(turn.turn.commands, store: store)
                        messages.append(reply)
                    }
                }
            } catch {
                messages.append(ChatMessage(role: .error, text: error.localizedDescription))
            }
            busy = false
        }
    }

    func confirm(_ message: ChatMessage, store: DocumentStore) {
        guard let i = messages.firstIndex(where: { $0.id == message.id }) else { return }
        if message.pending.isEmpty {
            messages[i] = message      // declined
            return
        }
        var m = message
        m.applied = apply(message.pending, store: store)
        m.pending = []
        m.awaitingConfirmation = false
        messages[i] = m
    }

    private func apply(_ commands: [DocumentCommand], store: DocumentStore) -> [String] {
        let report = store.run(commands)
        return report.split(separator: "\n").map(String.init)
    }

    /// Keep the last few exchanges. The document description is re-sent every turn and
    /// is the expensive part, so a long transcript buys little and costs a lot.
    private func trimHistory() {
        let keep = 8
        if history.count > keep { history.removeFirst(history.count - keep) }
    }
}
