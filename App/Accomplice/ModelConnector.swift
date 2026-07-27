import AccompliceCore
import Foundation

/// Talks to a local Ollama instance or to OpenRouter.
///
/// Same arrangement as Pelocan: local by default, cloud optional with the user's own
/// key. An operation over a layer tree does not need a frontier model — it's reading
/// a few hundred lines of structured text and emitting a handful of JSON objects,
/// which a 30B coder model does comfortably and privately.
///
/// The connector deliberately knows nothing about the document. It sends a
/// description and a schema, and returns commands. Everything that actually changes
/// the file goes through DocumentStore.run, so a model can't reach past the
/// scriptable API into internals — and every change it makes is one undo away.
struct ModelConnector {

    enum Backend: String, CaseIterable, Identifiable, Sendable {
        case ollama, openRouter
        var id: String { rawValue }
        var title: String { self == .ollama ? "Local (Ollama)" : "OpenRouter" }
    }

    struct Settings {
        var backend: Backend = .ollama
        var ollamaHost = "http://127.0.0.1:11434"
        var model = "qwen3-coder:30b"
        var openRouterKey = ""
        var openRouterModel = "anthropic/claude-sonnet-4.5"
    }

    enum Failure: LocalizedError {
        case noKey
        case unreachable(String)
        case badResponse(String)
        case noCommands(String)

        var errorDescription: String? {
            switch self {
            case .noKey: return "Add an OpenRouter key in Settings, or switch to a local model."
            case .unreachable(let s): return "Couldn't reach the model: \(s)"
            case .badResponse(let s): return "The model's reply couldn't be read: \(s)"
            case .noCommands(let s): return "No commands in the reply.\n\n\(s)"
            }
        }
    }

    var settings: Settings

    /// One turn of a conversation.
    ///
    /// The document description is re-sent every turn rather than kept in history:
    /// it changes after every edit, and stale state is worse than no state.
    func converse(request: String,
                  document: String,
                  history: [(role: String, content: String)]) async throws -> (turn: ModelTurn, raw: String) {
        let system = ModelPrompt.system
        var messages: [[String: String]] = [["role": "system", "content": system]]
        for h in history { messages.append(["role": h.role, "content": h.content]) }
        messages.append(["role": "user",
                         "content": ModelPrompt.user(document: document, request: request)])

        let raw = try await complete(messages: messages)
        let cleaned = ModelConnector.stripFences(raw)
        let turn = ModelTurn.decode(Data(cleaned.utf8))
        guard !turn.say.isEmpty || !turn.commands.isEmpty else { throw Failure.noCommands(raw) }
        return (turn, cleaned)
    }

    // MARK: - Transport

    private func complete(messages: [[String: String]]) async throws -> String {
        switch settings.backend {
        case .ollama: return try await ollama(messages)
        case .openRouter: return try await openRouter(messages)
        }
    }

    private func ollama(_ messages: [[String: String]]) async throws -> String {
        guard let url = URL(string: settings.ollamaHost + "/api/chat") else {
            throw Failure.unreachable("bad host")
        }
        let body: [String: Any] = [
            "model": settings.model,
            "stream": false,
            // Deterministic: the same request should produce the same edit twice.
            "options": ["temperature": 0.1],
            "format": "json",
            "messages": messages,
        ]
        let json = try await post(url, body: body, headers: [:])
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw Failure.badResponse(String(describing: json))
        }
        return content
    }

    private func openRouter(_ messages: [[String: String]]) async throws -> String {
        guard !settings.openRouterKey.isEmpty else { throw Failure.noKey }
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw Failure.unreachable("bad url")
        }
        let body: [String: Any] = [
            "model": settings.openRouterModel,
            "temperature": 0.1,
            "response_format": ["type": "json_object"],
            "messages": messages,
        ]
        let json = try await post(url, body: body, headers: [
            "Authorization": "Bearer \(settings.openRouterKey)",
            "HTTP-Referer": "https://accomplice.app",
            "X-Title": "Accomplice",
        ])
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw Failure.badResponse(String(describing: json))
        }
        return content
    }

    private func post(_ url: URL, body: [String: Any], headers: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw Failure.badResponse("HTTP \(http.statusCode): \(String(decoding: data, as: UTF8.self).prefix(300))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return json
    }

    /// Models wrap JSON in ``` fences even when told not to. Cheaper to tolerate it
    /// than to spend a round trip correcting it.
    static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let firstNewline = t.firstIndex(of: "\n") { t = String(t[t.index(after: firstNewline)...]) }
            if let fence = t.range(of: "```", options: .backwards) { t = String(t[..<fence.lowerBound]) }
        }
        // Some models narrate before the JSON; take the outermost object or array.
        if let start = t.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let end = t.lastIndex(where: { $0 == "}" || $0 == "]" }), start < end {
            t = String(t[start...end])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Which local models are installed, for the settings picker.
    static func localModels(host: String) async -> [String] {
        guard let url = URL(string: host + "/api/tags"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }
}
