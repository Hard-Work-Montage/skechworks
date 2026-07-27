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
