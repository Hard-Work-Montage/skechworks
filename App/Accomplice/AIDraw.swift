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
        /// What each pass scored, in order — including the ones thrown away.
        ///
        /// Kept because "is four passes right?" is a question about this list and
        /// nothing else, and it used to be discarded the moment it was computed.
        var scores: [Double] = []
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

    /// The most it will look. Higher than it was, because it no longer costs
    /// anything to allow: the loop stops on its own once a pass stops paying,
    /// so this is a ceiling rather than a quota.
    static let passes = 6

    /// How many passes in a row may fail to improve before it gives up.
    ///
    /// One bad pass is worth forgiving — the model is told the pass was thrown
    /// away and often corrects on the next. Two in a row is a plateau, and the
    /// drawing that comes back from a plateau is the one already in `best`.
    static let patience = 2

    static func trace(source: CGImage, size: CGSize, connector: ModelConnector,
                      progress: (String) -> Void = { _ in },
                      preview: ([Layer]) -> Void = { _ in }) async throws -> Outcome {

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
            .system(ModelPrompt.trace(width: size.width, height: size.height,
                                      lineArt: stats.verdict == .lineArt)),
            .user(opening, images: [sourcePNG]),
        ]
        var say = ""
        var plan = ""
        var used = 0
        var scores: [Double] = []
        var stale = 0

        for pass in 1...passes {
            used = pass
            progress(pass == 1 ? "Looking at the picture…" : "Pass \(pass) of \(passes)…")

            // Only the newest turn carries pictures. The older ones are already
            // summarised by the drawing itself, and left in they'd blow the request
            // size for nothing.
            let (turn, _) = try await connector.respond(to: trimmed(messages), purpose: .trace)
            if !turn.say.isEmpty { say = turn.say }
            // The first pass writes the parts list and later passes correct
            // against it, so a replan only replaces it if it actually said
            // something. A pass that returns no plan is still working from the
            // one it wrote.
            if !turn.plan.isEmpty { plan = turn.plan }
            guard !turn.commands.isEmpty else { break }

            var candidate = best
            _ = candidate.run(turn.commands)
            guard let attempt = Compare.render(candidate, bounds: area, matching: source) else { break }
            let score = Compare.inkAgreement(attempt, source)

            // A pass that made it worse is thrown away, and the model is told so
            // rather than being handed its own bad work to build on. This is what
            // makes "try something ambitious" safe.
            let improved = score > bestScore
            scores.append(score)
            // One line per pass that stays put: what this attempt scored, how many
            // shapes it drew, and whether it was kept. Reading three of those back
            // says more about why a drawing came out as it did than the final
            // number ever does.
            let pct = Int((score * 100).rounded())
            let shapes = candidate.layers.count
            progress("Pass \(pass): \(shapes) shape\(shapes == 1 ? "" : "s"), \(pct)%"
                     + (improved ? " — kept" : " — worse than \(Int((bestScore * 100).rounded()))%, thrown away"))
            if improved {
                best = candidate
                bestScore = score
                stale = 0
                // Show the work as it happens. Only improvements go up, so the
                // canvas never flickers backwards through an attempt that was
                // thrown away.
                preview(best.layers)
            } else {
                stale += 1
            }

            // Every run in the arena write-up ended below its own mid-run peak,
            // so the last drawing is the wrong one to keep. This loop already
            // keeps the best rather than the last; stopping at a plateau just
            // means not paying for the passes that were going to drift.
            if stale >= patience {
                progress("Stopped early — the last \(stale) passes didn't improve on \(Int((bestScore * 100).rounded()))%")
                break
            }
            guard pass < passes else { break }

            // Show it what it's actually building on: its own attempt if that was
            // kept, otherwise the drawing as it stood before this pass.
            let shown = improved ? attempt : (Compare.render(best, bounds: area, matching: source) ?? attempt)
            guard let attemptPNG = Renderer.png(shown) else { break }
            // The overlay is the useful picture. The other two are context.
            let diff = Compare.overlay(shown, source).flatMap { Renderer.png($0) }
            let report = Compare.report(shown, against: source, bounds: area, cells: 12)
            // Tracing an outline drawing with solid shapes is the one failure the
            // overlay can't teach: it shows as one huge red mass, which reads as
            // everything being in the wrong place. Named for what it is instead.
            let flooded = stats.verdict == .lineArt && filled(best.layers)
            messages.append(.assistant(turn.say.isEmpty ? "(drew it)" : turn.say))
            messages.append(.user(ModelPrompt.traceAgain(report: report, pass: pass, plan: plan,
                                                         filledLineArt: flooded),
                                  images: [sourcePNG, attemptPNG, diff].compactMap { $0 }))
        }

        guard !best.layers.isEmpty else { throw Refusal.nothingDrawn }
        return Outcome(layers: best.layers, score: bestScore, passes: used, say: say, scores: scores)
    }

    /// Whether the drawing is solid shapes rather than hollow outlines.
    ///
    /// Judged on the majority: one filled dot among ten strokes is a dot, and
    /// saying "you filled them" about that would be wrong and confusing.
    private static func filled(_ layers: [Layer]) -> Bool {
        var solid = 0, hollow = 0
        func walk(_ ls: [Layer]) {
            for l in ls {
                if case .group(let kids) = l.kind { walk(kids); continue }
                let hasFill = !l.style.fills.isEmpty
                let hasBorder = !l.style.borders.isEmpty
                if hasFill && !hasBorder { solid += 1 } else if hasBorder { hollow += 1 }
            }
        }
        walk(layers)
        return solid > hollow
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
