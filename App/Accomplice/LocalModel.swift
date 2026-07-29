import Foundation
import SwiftUI

/// Getting the local model onto the machine, and saying honestly where that's up to.
///
/// The app ships without a model. Chat is the one feature that can't work out of the
/// box, so the setup for it has to be visible and finishable in the app rather than
/// being a paragraph of instructions the user is expected to go and follow.
///
/// Two things have to be true before chat works: Ollama is running, and the model is
/// pulled. Those fail differently and are fixed differently, so they're reported
/// separately — "couldn't reach the model" told you neither.
@MainActor
final class LocalModel: ObservableObject {

    /// 18 GB, which is a lot to ask — and it is still the right default, because it is
    /// the only local model measured correct on a real document with the real prompt.
    ///
    /// Smaller ones were tried properly and failed in the way that matters. Asked to
    /// make every text layer 50% opacity on a 500-layer file, qwen3.5:4b (3.4 GB)
    /// matched `path` + `#ffffff` instead of `text` and changed 171 wrong layers,
    /// three runs out of three, reporting success each time. gemma4:12b (7.7 GB)
    /// couldn't find the text layers at all. Both dropped "black" from "update the
    /// black fills", which turns a targeted recolour into a silent global one.
    ///
    /// A wrong edit that reports success is worse than an error, so download size
    /// loses to this. Anyone who would rather have the smaller model can pull it in
    /// Ollama and pick it here.
    /// Nonisolated so defaults elsewhere can name it without hopping to the main actor.
    nonisolated static let recommended = "qwen3-coder:30b"
    nonisolated static let recommendedSize = "18 GB"

    enum State: Equatable {
        case checking
        case noOllama
        case missing                       // Ollama is up, the model isn't there
        case downloading(fraction: Double, detail: String)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .checking
    @Published private(set) var installed: [String] = []

    private var host: String
    private var pull: Task<Void, Never>?

    init(host: String) { self.host = host }

    var isReady: Bool { state == .ready }

    /// True once the user could plausibly use chat — either the model is here, or
    /// they've pointed the app at a cloud key instead.
    func refresh(host: String, wanted: String) async {
        self.host = host
        if case .downloading = state { return }      // don't stomp a running pull
        state = .checking
        guard let names = await tags() else {
            state = .noOllama
            installed = []
            return
        }
        installed = names
        // Ollama reports "qwen3.5:4b"; a user who typed "qwen3.5" means the same
        // thing, and being pedantic about the tag here reads as a broken install.
        state = names.contains(where: { $0 == wanted || $0.hasPrefix(wanted + ":") })
            ? .ready : .missing
    }

    private func tags() async -> [String]? {
        guard let url = URL(string: host + "/api/tags") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    // MARK: - Downloading

    /// Pulls the model, reporting real progress.
    ///
    /// Ollama streams one JSON object per line with bytes so far, so the user gets a
    /// bar and a size rather than a spinner. A multi-gigabyte download behind an
    /// indeterminate spinner is indistinguishable from a hang.
    func download(_ model: String) {
        pull?.cancel()
        state = .downloading(fraction: 0, detail: "Starting…")
        pull = Task { [host] in
            guard let url = URL(string: host + "/api/pull") else {
                state = .failed("Bad Ollama address")
                return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 3600
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(
                withJSONObject: ["model": model, "stream": true])

            do {
                let (lines, response) = try await URLSession.shared.bytes(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    state = .failed("Ollama refused the download (HTTP \(http.statusCode)). "
                                    + "Check the model name.")
                    return
                }
                for try await line in lines.lines {
                    if Task.isCancelled { return }
                    guard let d = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                    else { continue }

                    if let error = json["error"] as? String {
                        state = .failed(error)
                        return
                    }
                    let status = json["status"] as? String ?? ""
                    if let total = json["total"] as? Double, total > 0 {
                        let done = json["completed"] as? Double ?? 0
                        state = .downloading(fraction: done / total,
                                             detail: "\(Self.size(done)) of \(Self.size(total))")
                    } else {
                        state = .downloading(fraction: 0, detail: status.capitalized)
                    }
                    if status == "success" {
                        state = .ready
                        installed = await tags() ?? installed
                        return
                    }
                }
                // The stream ended without saying "success" — verify rather than assume.
                let names = await tags() ?? []
                state = names.contains(where: { $0 == model || $0.hasPrefix(model + ":") })
                    ? .ready : .failed("The download ended early. Try again.")
            } catch {
                if !Task.isCancelled { state = .failed(error.localizedDescription) }
            }
        }
    }

    func cancelDownload() {
        pull?.cancel()
        pull = nil
        state = .missing
    }

    private static func size(_ bytes: Double) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}
