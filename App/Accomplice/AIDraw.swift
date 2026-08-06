import AccompliceCore
import CoreGraphics
import Foundation

/// Redrawing a picture as shapes, as a loop rather than a single guess.
///
/// A vision model asked to trace something is poor at emitting coordinates in one
/// shot and good at correcting them once it can see what it got wrong. So it draws,
/// the drawing is rendered and scored against the original, and the score and the
/// error map go back with the next request. Three passes of that beats one careful
/// attempt, and it degrades honestly: a pass that makes things worse is thrown away
/// rather than kept.
///
/// The result is deliberately different in kind from Vectorize. That gives correct
/// pixels as hundreds of unnamed paths. This gives a handful of named shapes that
/// are still real ellipses and strokes, which is the only version you can edit
/// afterwards.
@MainActor
enum AIDraw {

    struct Outcome {
        var layers: [Layer]
        var score: Double
        var passes: Int
        var say: String
    }

    enum Refusal: LocalizedError {
        case notWorthTracing(ImageStats.Verdict)
        case nothingDrawn

        var errorDescription: String? {
            switch self {
            case .notWorthTracing:
                return "This is a photograph, not a drawing. Vectorize will do better with it."
            case .nothingDrawn:
                return "Nothing came back that improved on an empty page."
            }
        }
    }

    /// How many times to look and correct. Three is where it stops paying: the
    /// first pass gets the shapes, the second fixes placement, and the third is
    /// usually the last one that changes the score at all.
    /// How many times to look and correct.
    ///
    /// Four rather than three now the score means something: with a metric that
    /// barely moved there was nothing to be gained from another look.
    static let passes = 4

    static func trace(source: CGImage, size: CGSize, connector: ModelConnector,
                      progress: (String) -> Void = { _ in }) async throws -> Outcome {

        let stats = ImageStats.measure(source)
        guard stats.verdict.traceable else { throw Refusal.notWorthTracing(stats.verdict) }
        guard let sourcePNG = Renderer.png(source) else { throw Refusal.nothingDrawn }

        let area = CGRect(origin: .zero, size: size)
        var best = Page(name: "trace")
        // The baseline is an empty page. Anything the model draws has to beat
        // drawing nothing, or it isn't worth putting in the document.
        // Scored on the ink. Pixel agreement is dominated by the background: this
        // icon is four fifths white, so an EMPTY page scored 82% and a real trace
        // scored 82%, and three passes of the loop were steering on noise.
        var bestScore = Compare.render(best, bounds: area, matching: source)
            .map { Compare.inkAgreement($0, source) } ?? 0

        // Thickness is measured off the source and told, not left to the eye —
        // a wrong strokeWidth caps the score on its own, and looks like a
        // placement problem the loop then chases for the rest of its passes.
        let opening = [stats.summary, stats.strokeWidthHint(for: size), "Redraw this picture."]
            .compactMap { $0 }.joined(separator: "\n\n")
        var messages: [ModelConnector.Message] = [
            .system(ModelPrompt.trace(width: size.width, height: size.height)),
            .user(opening, images: [sourcePNG]),
        ]
        var say = ""
        var used = 0

        for pass in 1...passes {
            used = pass
            progress(pass == 1 ? "Looking at the picture…" : "Pass \(pass) of \(passes)…")

            // Only the newest turn carries pictures. The older ones are already
            // summarised by the drawing itself, and left in they'd blow the request
            // size for nothing.
            let (turn, _) = try await connector.respond(to: trimmed(messages))
            if !turn.say.isEmpty { say = turn.say }
            guard !turn.commands.isEmpty else { break }

            var candidate = best
            _ = candidate.run(turn.commands)
            guard let attempt = Compare.render(candidate, bounds: area, matching: source) else { break }
            let score = Compare.inkAgreement(attempt, source)

            // A pass that made it worse is thrown away, and the model is told so
            // rather than being handed its own bad work to build on. This is what
            // makes "try something ambitious" safe.
            let improved = score > bestScore
            if improved {
                best = candidate
                bestScore = score
            }
            guard pass < passes else { break }

            // Show it what it's actually building on: its own attempt if that was
            // kept, otherwise the drawing as it stood before this pass.
            let shown = improved ? attempt : (Compare.render(best, bounds: area, matching: source) ?? attempt)
            guard let attemptPNG = Renderer.png(shown) else { break }
            // The overlay is the useful picture. The other two are context.
            let diff = Compare.overlay(shown, source).flatMap { Renderer.png($0) }
            let report = Compare.report(shown, against: source, bounds: area, cells: 12)
            messages.append(.assistant(turn.say.isEmpty ? "(drew it)" : turn.say))
            messages.append(.user(ModelPrompt.traceAgain(report: report, pass: pass),
                                  images: [sourcePNG, attemptPNG, diff].compactMap { $0 }))
        }

        guard !best.layers.isEmpty else { throw Refusal.nothingDrawn }
        return Outcome(layers: best.layers, score: bestScore, passes: used, say: say)
    }

    private static func trimmed(_ messages: [ModelConnector.Message]) -> [ModelConnector.Message] {
        guard let last = messages.lastIndex(where: { !$0.images.isEmpty }) else { return messages }
        return messages.enumerated().map { index, message in
            guard index != last else { return message }
            var stripped = message
            stripped.images = []
            return stripped
        }
    }
}
