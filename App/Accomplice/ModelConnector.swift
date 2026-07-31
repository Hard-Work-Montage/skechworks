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
        case ollama, openRouter, accomplice
        var id: String { rawValue }

        var title: String {
            switch self {
            case .ollama: return "On this Mac"
            case .openRouter: return "OpenRouter account"
            case .accomplice: return "Accomplice account"
            }
        }

        var detail: String {
            switch self {
            case .ollama:
                return "A one-time download. Nothing you draw or type leaves the machine."
            case .openRouter:
                return "Your own OpenRouter account, billed to you. No download."
            case .accomplice:
                return "Sign in and use Accomplice tokens. No download, no separate account."
            }
        }
    }

    struct Settings {
        var backend: Backend = .ollama
        var ollamaHost = "http://127.0.0.1:11434"
        var model = LocalModel.recommended
        var openRouterModel = "anthropic/claude-sonnet-4.5"
        /// Where Accomplice accounts live. Was configurable while accomplice.ai
        /// still redirected elsewhere; the service is home now, so it's baked in —
        /// a stored blank in the old setting once quietly broke sign-in.
        let accompliceHost = "https://accomplice.ai"

        /// Read at the point of use rather than held, so disconnecting takes effect
        /// at once and no key sits in memory longer than a request.
        var openRouterKey: String { Credentials.get(.openRouterKey) ?? "" }
        var accompliceToken: String { Credentials.get(.accompliceToken) ?? "" }
    }

    enum Failure: LocalizedError {
        case noKey
        case notSignedIn
        case unreachable(String)
        case badResponse(String)
        case noCommands(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in to Accomplice in Settings, or switch to another option."
            case .noKey: return "Connect your OpenRouter account in Settings, or switch to another option."
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
        case .accomplice: return try await accomplice(messages)
        }
    }

    /// Accomplice's own endpoint, which fronts a provider and bills tokens to the
    /// signed-in account. Deliberately the same OpenAI-shaped request as OpenRouter,
    /// so the only thing that differs between "your key" and "our tokens" is where
    /// it's addressed and who pays.
    private func accomplice(_ messages: [[String: String]]) async throws -> String {
        let token = settings.accompliceToken
        guard !token.isEmpty else { throw Failure.notSignedIn }
        guard let url = URL(string: settings.accompliceHost + "/api/v1/chat/completions") else {
            throw Failure.unreachable("bad url")
        }
        let body: [String: Any] = [
            "temperature": 0.1,
            "response_format": ["type": "json_object"],
            "messages": messages,
        ]
        let json = try await post(url, body: body, headers: [
            "Authorization": "Bearer \(token)",
            "X-Title": "Accomplice",
        ])
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw Failure.badResponse(String(describing: json))
        }
        return content
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

    /// Tools ▸ Vectorize: a bitmap goes to the account service, a traced SVG
    /// comes back. Static because it doesn't depend on the chat backend choice,
    /// only on the signed-in account.
    static func vectorize(png: Data, style: String = "color") async throws -> (svg: String, remaining: Double?) {
        let token = Credentials.get(.accompliceToken) ?? ""
        guard !token.isEmpty else { throw Failure.notSignedIn }
        guard let url = URL(string: Settings().accompliceHost + "/api/v1/vectorize") else {
            throw Failure.unreachable("bad url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // The redraw alone can take a minute or two; this is the one call in the
        // app that is genuinely slow, and it says so in the status bar.
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "image": png.base64EncodedString(), "style": style,
        ])
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let message = (json["error"] as? [String: Any])?["message"] as? String
            throw Failure.badResponse(message ?? "HTTP \(http.statusCode)")
        }
        guard let svg = json["svg"] as? String else {
            throw Failure.badResponse("no SVG in the reply")
        }
        return (svg, json["credits_remaining"] as? Double)
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
