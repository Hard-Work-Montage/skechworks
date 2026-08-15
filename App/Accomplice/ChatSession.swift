import AccompliceCore
import AppKit
import Foundation
import SwiftUI

enum ChatRole { case user, assistant, error }

/// A button in the transcript, waiting on a yes.
///
/// Spending money was the only thing it was ever for, and it is still the main
/// one. Buying credits and opening Settings arrived later and want the same
/// thing: a run that stopped, the reason it stopped, and the one press that
/// gets past it sitting right underneath.
struct Offer {
    var label: String
    /// What the free pass already produced, said plainly, so the choice is
    /// between two things rather than between a button and a mystery.
    var note: String = ""
    var run: @MainActor () -> Void
}

struct ChatMessage: Identifiable {
    let id = UUID()
    var role: ChatRole
    var text: String
    /// One line per command that ran, so what changed is never a guess.
    var applied: [String] = []
    /// What that list is a list OF, for the fold-away summary. "6 shapes" reads
    /// as a result; "6 changes" reads as an edit; "6 things" reads as nothing.
    var appliedNoun = "changes"
    /// Held back pending a yes — only for the destructive-or-huge case.
    var pending: [DocumentCommand] = []
    /// Commands that arrived but couldn't be read.
    var problems: [String] = []
    /// The model spoke but nothing ran. Shown, never hidden.
    var nothingHappened = false
    var confirmPrompt = ""
    var awaitingConfirmation = false

    /// An offer to spend money, which is never taken up on its own.
    ///
    /// Remove fills a hole from its surroundings for nothing, and grades what
    /// it did. When the surroundings are too busy for that to be honest — a
    /// photograph rather than flat artwork — it says so and leaves this behind
    /// rather than quietly billing forty cents for the better answer.
    var offer: Offer?

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
    @Published var messages: [ChatMessage] = [] { didSet { scheduleKeep() } }
    @Published var busy = false

    /// Where this conversation is filed. Set when the document gets a name, and
    /// on a Save As it moves with it.
    var documentURL: URL? {
        didSet {
            guard documentURL != oldValue else { return }
            if let documentURL, messages.isEmpty {
                messages = ChatArchive.load(for: documentURL)
            } else {
                keep()
            }
        }
    }

    private var keepTask: Task<Void, Never>?

    /// Written a moment after things settle rather than on every line, because a
    /// run appends a dozen in a second and each one would be a file write.
    private func scheduleKeep() {
        guard documentURL != nil else { return }
        keepTask?.cancel()
        keepTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            keep()
        }
    }

    /// Now, for the moments that can't wait — closing, quitting.
    func keep() {
        guard let documentURL else { return }
        keepTask?.cancel()
        ChatArchive.save(messages, for: documentURL)
    }

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
        // this is now the only place the run is described. Same keys ContentView
        // binds to, so the panel opens and unfolds.
        UserDefaults.standard.set(true, forKey: "showChat")
        UserDefaults.standard.set(false, forKey: "chatCollapsed")
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
    func endActivity(_ id: UUID, text: String, applied: [String] = [],
                     noun: String = "changes", failed: Bool = false) {
        stopHandler = nil
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].running = false
        messages[i].text = text
        messages[i].applied = applied
        messages[i].appliedNoun = noun
        if failed { messages[i].role = .error }
    }

    /// Leaves a button in the transcript rather than spending on the person's
    /// behalf. The last entry is the one that just explained why.
    func offerPaidRemove(label: String, note: String = "", run: @escaping @MainActor () -> Void) {
        guard let i = messages.indices.last else { return }
        // Remembered by id, not by position. Clearing "the first message that
        // has an offer" is right only while there is one — after a couple of
        // goes the transcript holds several, and taking the newest put the
        // oldest away and left the one just pressed sitting there asking to be
        // pressed again.
        let taken = messages[i].id
        messages[i].offer = Offer(label: label, note: note) { [weak self] in
            self?.declineOffer(taken)      // one press only: it goes as it is taken
            run()
        }
    }

    /// A tool declining to start, said where the tools say everything else.
    ///
    /// These landed in the status line and nowhere else, which is grey type
    /// under the canvas that the next thing you do wipes out. Pick Vectorize
    /// with a group selected and the menu closes, nothing appears, and the app
    /// has told you nothing you can see. Opens the panel for the same reason a
    /// run does: a report nobody can read isn't one.
    @discardableResult
    func problem(_ text: String) -> UUID {
        UserDefaults.standard.set(true, forKey: "showChat")
        UserDefaults.standard.set(false, forKey: "chatCollapsed")
        let m = ChatMessage(role: .error, text: text)
        messages.append(m)
        return m.id
    }

    /// Running out of credits is the one failure with a button attached.
    ///
    /// The line above it already says what the job costs and what's left, so
    /// this is the button and nothing else. It doesn't clear itself the way a
    /// paid offer does — pressing it opens a web page rather than spending, and
    /// coming back from a checkout that didn't finish should leave the way back
    /// where it was.
    func offerCredits(on id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].offer = Offer(label: "Buy credits") {
            NSWorkspace.shared.open(ModelConnector.creditsURL)
        }
    }

    /// The same shape for the failure whose fix is a setting rather than a
    /// purchase: the sentence says what's missing, the button goes and gets it.
    func offerSettings(on id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].offer = Offer(label: "Open Settings…") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    /// Puts the offer away without taking it. The activity it came from stays
    /// in the transcript — only the invitation to spend goes.
    func declineOffer(_ id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].offer = nil
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
                if let failure = error as? ModelConnector.Failure, case .outOfCredits = failure,
                   let id = messages.last?.id {
                    offerCredits(on: id)
                }
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
