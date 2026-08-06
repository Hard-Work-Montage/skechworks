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

        /// What's configured, straight from defaults.
        ///
        /// The chat panel holds these as @AppStorage so its view updates, but a menu
        /// command has no view to read them from. Same keys, so the two can't
        /// disagree about which backend is in use.
        static var current: Settings {
            let defaults = UserDefaults.standard
            var s = Settings()
            s.backend = Backend(rawValue: defaults.string(forKey: "ai.backend") ?? "") ?? s.backend
            s.ollamaHost = defaults.string(forKey: "ai.ollamaHost") ?? s.ollamaHost
            s.model = defaults.string(forKey: "ai.model") ?? s.model
            s.openRouterModel = defaults.string(forKey: "ai.openRouterModel") ?? s.openRouterModel
            return s
        }
    }

    enum Failure: LocalizedError {
        case noKey
        case notSignedIn
        case unreachable(String)
        case badResponse(String)
        case noCommands(String)
        case cannotSee
        /// The service turned the request down and said why in words worth showing.
        case refused(String)
        case outOfCredits(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in to Accomplice in Settings, or switch to another option."
            case .noKey: return "Connect your OpenRouter account in Settings, or switch to another option."
            case .unreachable(let s): return "Couldn't reach the model: \(s)"
            case .badResponse(let s): return "The model's reply couldn't be read: \(s)"
            case .noCommands(let s): return "No commands in the reply.\n\n\(s)"
            case .cannotSee:
                return "A model on this Mac can't be shown a picture. Switch to OpenRouter or your Accomplice account in Settings."
            case .refused(let s): return s
            case .outOfCredits(let s): return s
            }
        }
    }

    var settings: Settings

    /// One thing said to the model, with anything it needs to look at.
    ///
    /// Pictures ride along with the words rather than in a separate field because
    /// that's the shape every provider takes, and because the two belong together:
    /// "this is what you drew, this is what it should look like" is one thought.
    struct Message {
        var role: String
        var text: String
        var images: [Data] = []      // PNG

        static func user(_ text: String, images: [Data] = []) -> Message {
            Message(role: "user", text: text, images: images)
        }
        static func system(_ text: String) -> Message { Message(role: "system", text: text) }
        static func assistant(_ text: String) -> Message { Message(role: "assistant", text: text) }

        /// Plain content when there's nothing to see, blocks when there is. Sending
        /// blocks unconditionally works with the big providers and breaks smaller
        /// ones, and the overwhelming majority of turns carry no picture at all.
        var payload: [String: Any] {
            guard !images.isEmpty else { return ["role": role, "content": text] }
            var blocks: [[String: Any]] = [["type": "text", "text": text]]
            for png in images {
                blocks.append(["type": "image_url",
                               "image_url": ["url": "data:image/png;base64,\(png.base64EncodedString())"]])
            }
            return ["role": role, "content": blocks]
        }
    }

    /// One turn of a conversation.
    ///
    /// The document description is re-sent every turn rather than kept in history:
    /// it changes after every edit, and stale state is worse than no state.
    func converse(request: String,
                  document: String,
                  history: [(role: String, content: String)]) async throws -> (turn: ModelTurn, raw: String) {
        var messages: [Message] = [.system(ModelPrompt.system)]
        for h in history { messages.append(Message(role: h.role, text: h.content)) }
        messages.append(.user(ModelPrompt.user(document: document, request: request)))
        return try await respond(to: messages)
    }

    /// A turn built by hand, for the jobs that aren't chat — tracing shows the model
    /// a picture, its own attempt, and where the two differ.
    func respond(to messages: [Message], purpose: Purpose = .chat) async throws -> (turn: ModelTurn, raw: String) {
        if settings.backend == .ollama, messages.contains(where: { !$0.images.isEmpty }) {
            throw Failure.cannotSee
        }
        let raw = try await complete(messages: messages.map(\.payload), purpose: purpose)
        let cleaned = ModelConnector.stripFences(raw)
        let turn = ModelTurn.decode(Data(cleaned.utf8))
        guard !turn.say.isEmpty || !turn.commands.isEmpty else { throw Failure.noCommands(raw) }
        return (turn, cleaned)
    }

    // MARK: - Transport

    /// What the request is FOR. The account service picks the model from this,
    /// because the gap between models on tracing is enormous and the price of the
    /// right one is only worth paying for the job that needs it.
    enum Purpose: String {
        case chat
        /// The everyday trace: a cheap, quick, streaky model.
        case trace
        /// The good one, when the drawing matters more than the wait.
        case traceBest = "trace_best"

        /// How long to wait. The two trace models are three hundred seconds
        /// apart — a Fable pass measured 277 — and a flat two minutes hung up
        /// on it every time, reporting a model that was working perfectly well
        /// as unreachable.
        var timeout: TimeInterval {
            switch self {
            case .chat: return 120
            case .trace: return 120
            case .traceBest: return 420
            }
        }

        /// How many correction passes are worth paying for after the opening.
        ///
        /// Correcting rescues a bad drawing and spoils a good one, and the
        /// expensive model doesn't draw bad ones — so on that tier the opening
        /// IS the drawing, and the local cleanup does the rest for nothing.
        /// Another Fable pass is four minutes and 88 cents to be told the
        /// drawing was already better before.
        var passes: Int {
            switch self {
            case .chat: return 1
            case .trace: return 6
            case .traceBest: return 1
            }
        }

        /// How many openings to draw at once and pick between.
        ///
        /// Buying more rolls of the dice only makes sense when a roll is cheap
        /// and quick. Five of the cheap model costs five cents and no extra
        /// waiting; five of the expensive one would be $4.40 and no faster than
        /// the slowest of them.
        var attempts: Int {
            switch self {
            case .chat: return 1
            case .trace: return 5
            case .traceBest: return 1
            }
        }
    }

    private func complete(messages: [[String: Any]], purpose: Purpose) async throws -> String {
        switch settings.backend {
        case .ollama: return try await ollama(messages)
        case .openRouter: return try await openRouter(messages)
        case .accomplice: return try await accomplice(messages, purpose: purpose)
        }
    }

    /// Accomplice's own endpoint, which fronts a provider and bills tokens to the
    /// signed-in account. Deliberately the same OpenAI-shaped request as OpenRouter,
    /// so the only thing that differs between "your key" and "our tokens" is where
    /// it's addressed and who pays.
    private func accomplice(_ messages: [[String: Any]], purpose: Purpose = .chat) async throws -> String {
        let token = settings.accompliceToken
        guard !token.isEmpty else { throw Failure.notSignedIn }
        guard let url = URL(string: settings.accompliceHost + "/api/v1/chat/completions") else {
            throw Failure.unreachable("bad url")
        }
        let body: [String: Any] = [
            "temperature": 0.1,
            "response_format": ["type": "json_object"],
            // The job, not the model. The service knows what each costs; a client
            // naming a model would be a client naming a price.
            "purpose": purpose.rawValue,
            "messages": messages,
        ]
        let json = try await post(url, body: body, headers: [
            "Authorization": "Bearer \(token)",
            "X-Title": "Accomplice",
        ], timeout: purpose.timeout)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw Failure.badResponse(String(describing: json))
        }
        return content
    }

    private func ollama(_ messages: [[String: Any]]) async throws -> String {
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

    private func openRouter(_ messages: [[String: Any]]) async throws -> String {
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

    /// Who's signed in and what they have to spend. Settings shows it; the app
    /// never needs more than this about the account.
    static func accountBalance() async throws -> (email: String, credits: Double) {
        let token = Credentials.get(.accompliceToken) ?? ""
        guard !token.isEmpty else { throw Failure.notSignedIn }
        guard let url = URL(string: Settings().accompliceHost + "/api/v1/me") else {
            throw Failure.unreachable("bad url")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        // A rejected token has to be told apart from a reply that didn't parse.
        // Both used to come back as "couldn't be read", so the one place you'd go
        // to check your sign-in showed a green tick and nothing else.
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw Failure.notSignedIn
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String,
              let credits = json["credits"] as? Double else {
            throw Failure.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return (email, credits)
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

    /// Tools ▸ Remove: a bitmap and the user's box go to the account service,
    /// the same image comes back with whatever the box marked painted out.
    /// The rect is in unit coordinates of the image.
    static func remove(png: Data, rect: CGRect) async throws -> (png: Data, remaining: Double?) {
        let token = Credentials.get(.accompliceToken) ?? ""
        guard !token.isEmpty else { throw Failure.notSignedIn }
        guard let url = URL(string: Settings().accompliceHost + "/api/v1/remove") else {
            throw Failure.unreachable("bad url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // A masked edit plus its quality check runs about as long as a
        // vectorize, and the status bar says so.
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "image": png.base64EncodedString(),
            "rect": ["x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height],
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
        guard let b64 = json["image"] as? String, let out = Data(base64Encoded: b64) else {
            throw Failure.badResponse("no image in the reply")
        }
        return (out, json["credits_remaining"] as? Double)
    }

    private func post(_ url: URL, body: [String: Any], headers: [String: String],
                      timeout: TimeInterval = 120) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
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
            // Every one of these services says what went wrong in plain words and
            // then wraps it in JSON. Show the words. A status line reading
            // `HTTP 401: {"error":{"message":…}}` makes the person read past the
            // punctuation to find the one sentence that tells them what to do.
            let said = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
            switch http.statusCode {
            case 401, 403:
                // The token is stale or gone, which is a thing to fix rather than a
                // thing to report.
                throw settings.backend == .openRouter ? Failure.noKey : Failure.notSignedIn
            case 402:
                throw Failure.outOfCredits(said ?? "You're out of credits.")
            default:
                throw Failure.refused(said ?? "The service returned \(http.statusCode).")
            }
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return json
    }

    /// Models wrap JSON in ``` fences even when told not to. Cheaper to tolerate it
    /// than to spend a round trip correcting it.
    /// Kept as the connector's name for it; the implementation lives in the core
    /// beside the parser that needs it, so the two can't drift apart.
    static func stripFences(_ s: String) -> String {
        String(data: DocumentCommand.unwrap(Data(s.utf8)), encoding: .utf8) ?? s
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
