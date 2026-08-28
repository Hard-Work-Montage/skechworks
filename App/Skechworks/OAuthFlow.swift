import AuthenticationServices
import CryptoKit
import Foundation

/// Sign-in without ever handling the password.
///
/// PKCE, which is the flow for an app that can't keep a client secret — a desktop app
/// can't, because anyone can open the bundle. The app invents a random verifier, sends
/// only its SHA-256, and proves possession at the exchange, so an intercepted callback
/// is worth nothing on its own.
///
/// The same shape serves OpenRouter and Skechworks; only the URLs differ. Pasting an
/// API key still works and isn't going away — some people prefer it, and it's the only
/// option for a key that isn't tied to an account.
@MainActor
final class OAuthFlow: NSObject {

    struct Provider {
        var name: String
        var authorize: URL
        /// Exchanges the one-time code for something durable. Nil for OpenRouter's
        /// flow, which returns the key from a fixed endpoint rather than a token URL.
        var exchange: URL
        var slot: Credentials.Slot
        /// What the exchange response calls the thing we keep.
        var tokenKey: String

        static let openRouter = Provider(
            name: "OpenRouter",
            authorize: URL(string: "https://openrouter.ai/auth")!,
            exchange: URL(string: "https://openrouter.ai/api/v1/auth/keys")!,
            slot: .openRouterKey,
            tokenKey: "key")

        /// Points at wherever Skechworks accounts end up living. skechworks.com
        /// currently redirects to pelocan.ai, so this is deliberately configurable
        /// rather than baked in — the app shouldn't need a release to follow a domain.
        static func skechworks(base: String) -> Provider {
            let root = base.hasSuffix("/") ? String(base.dropLast()) : base
            return Provider(
                name: "Skechworks",
                authorize: URL(string: root + "/oauth/authorize")!,
                exchange: URL(string: root + "/api/v1/oauth/token")!,
                slot: .skechworksToken,
                tokenKey: "access_token")
        }
    }

    enum Failure: LocalizedError {
        case cancelled
        case noCode
        case exchange(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign-in was cancelled."
            case .noCode: return "The sign-in didn't come back with a code."
            case .exchange(let s): return "Couldn't finish signing in: \(s)"
            }
        }
    }

    nonisolated static let callbackScheme = "skechworks"

    private var session: ASWebAuthenticationSession?

    /// Runs the whole flow and stores the result. Returns once the key is usable.
    func connect(_ provider: Provider) async throws {
        let verifier = Self.randomVerifier()
        let challenge = Self.challenge(for: verifier)
        let callback = "\(Self.callbackScheme)://oauth/\(provider.slot.rawValue)"

        var components = URLComponents(url: provider.authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            .init(name: "callback_url", value: callback),
            .init(name: "redirect_uri", value: callback),   // the other half of the world
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "response_type", value: "code"),
        ]

        let code = try await authorize(components.url!, callback: callback)
        let token = try await exchange(provider, code: code, verifier: verifier)
        guard Credentials.set(provider.slot, token) else {
            // The server said yes and the app then failed to keep the token. Saying
            // so beats silently landing back on the sign-in button.
            throw Failure.exchange("signed in, but the token couldn't be stored in the keychain")
        }
    }

    private func authorize(_ url: URL, callback: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = Self.makeSession(url: url, continuation: continuation)
            session.presentationContextProvider = self
            // Their existing browser session is the point — most people are already
            // signed in, so this is one click rather than a password.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { continuation.resume(throwing: Failure.cancelled) }
        }
    }

    /// Built in a nonisolated context, deliberately: AuthenticationServices invokes
    /// the completion on an XPC queue, and a closure formed inside this MainActor
    /// class inherits its isolation — the runtime then traps the moment the
    /// callback fires off the main thread. (@Sendable alone did not sever the
    /// inference; a nonisolated enclosing function does.) The continuation is safe
    /// to resume from any thread.
    private nonisolated static func makeSession(
        url: URL,
        continuation: CheckedContinuation<String, Error>
    ) -> ASWebAuthenticationSession {
        ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { returned, error in
            if let error {
                let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                continuation.resume(throwing: cancelled ? Failure.cancelled : error)
                return
            }
            guard let returned,
                  let items = URLComponents(url: returned, resolvingAgainstBaseURL: false)?.queryItems,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                continuation.resume(throwing: Failure.noCode)
                return
            }
            continuation.resume(returning: code)
        }
    }

    private func exchange(_ provider: Provider, code: String, verifier: String) async throws -> String {
        var req = URLRequest(url: provider.exchange)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "code": code,
            "code_verifier": verifier,
            "code_challenge_method": "S256",
            "grant_type": "authorization_code",
        ])

        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw Failure.exchange(error.localizedDescription) }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw Failure.exchange("HTTP \(http.statusCode) — \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json[provider.tokenKey] as? String, !token.isEmpty else {
            throw Failure.exchange(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return token
    }

    // MARK: - PKCE

    /// 32 random bytes, base64url. Long enough that guessing it is not a strategy.
    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Base64 as URLs allow it: no padding, and the two characters that would
    /// otherwise be re-encoded in a query string swapped out.
    static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension OAuthFlow: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApplication.shared.keyWindow ?? ASPresentationAnchor() }
    }
}
