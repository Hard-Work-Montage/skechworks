import SketchyworksCore
import CryptoKit
import Foundation
import OSLog

/// Keeping a conversation across quits.
///
/// The transcript belongs to the document — it's about that drawing, and it's
/// how a run explained itself — so it's kept per file rather than as one global
/// log. Beside the document rather than inside it: chatting isn't editing, and
/// folding it into the file would mark a document dirty for asking a question
/// and put a conversation into anything exported from it.
///
/// An unsaved document keeps nothing, which is the consistent answer: there's
/// no stable name to file it under, and the drawing itself isn't being kept
/// either.
@MainActor
enum ChatArchive {

    static var directoryOverride: URL?
    static var directory: URL {
        directoryOverride ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sketchyworks/Conversations", isDirectory: true)
    }

    /// Older messages fall off the top. Five hundred is far past anything worth
    /// scrolling back through and small enough that reading it is instant.
    static let keep = 500

    /// What survives a relaunch.
    ///
    /// Deliberately not the whole message. A pending confirmation must not come
    /// back — "this affects 40 layers, go ahead?" answered a week later, against
    /// a document that has moved on, is a trap rather than a convenience — and a
    /// spinner must not either, since nothing is running any more. That a run
    /// WAS going is worth keeping, though: it's the difference between a tool
    /// that never finished and one that never started.
    struct Stored: Codable {
        var role: String
        var text: String
        var applied: [String]
        var appliedNoun: String
        var problems: [String]
        var nothingHappened: Bool
        var activity: Bool
        var steps: [String]
        /// Optional so transcripts written before this decode as "not running".
        var running: Bool?
    }

    private static func file(for url: URL) -> URL {
        // Named by a digest of the path: readable names would collide across
        // folders, and the path itself isn't a legal filename.
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return directory.appendingPathComponent("\(name).json")
    }

    static func load(for url: URL) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: file(for: url)),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return stored.map { s in
            var m = ChatMessage(role: role(s.role), text: s.text)
            m.applied = s.applied
            m.appliedNoun = s.appliedNoun
            m.problems = s.problems
            m.nothingHappened = s.nothingHappened
            m.activity = s.activity
            m.steps = s.steps
            // A run that was still going when the app closed is not going now,
            // and it never will be. It used to come back as a bare title with
            // its working notes under it and no ending at all, which reads as a
            // tool that quietly did nothing.
            if s.running == true {
                m.role = .error
                m.text = "\(s.text) stopped when Sketchyworks closed."
            }
            return m
        }
    }

    static func save(_ messages: [ChatMessage], for url: URL) {
        let stored = messages.suffix(keep).map { m in
            Stored(role: name(m.role), text: m.text, applied: m.applied,
                   appliedNoun: m.appliedNoun, problems: m.problems,
                   nothingHappened: m.nothingHappened, activity: m.activity, steps: m.steps,
                   running: m.running)
        }
        let target = file(for: url)
        do {
            if stored.isEmpty {
                try? FileManager.default.removeItem(at: target)
                return
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: target, options: .atomic)
        } catch {
            // A conversation that fails to save is not worth interrupting anyone
            // over, but it shouldn't vanish without trace either.
            Logger(subsystem: "com.sketchyworks.Sketchyworks", category: "chat")
                .error("Couldn't keep the conversation: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func name(_ r: ChatRole) -> String {
        switch r {
        case .user: return "user"
        case .assistant: return "assistant"
        case .error: return "error"
        }
    }

    private static func role(_ s: String) -> ChatRole {
        switch s {
        case "user": return .user
        case "error": return .error
        default: return .assistant
        }
    }
}
