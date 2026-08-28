import SkechworksCore
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

        /// The tidied version, kept apart from the drawing it came from.
        ///
        /// It scores better by definition and still sometimes looks worse — the
        /// measure is ink overlap and the judge is an eye, and they disagree.
        /// So it goes into the document as its own undo step and `layers` stays
        /// as the model drew it: one ⌘Z drops the tidying and keeps the drawing.
        var tidied: Tidied?

        struct Tidied {
            var layers: [Layer]
            var from: Double
            var to: Double
            var tries: Int
        }
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

    /// Once a drawing is this good, correcting it makes it worse.
    ///
    /// Measured, twice: a 70% drawing came back 62% from the model that drew it
    /// and 40% from a cheaper one. Below this a weak opening really does climb —
    /// 19% to 34% over four passes — so the loop is worth running. Above it,
    /// every further pass is money and minutes spent to be told the drawing was
    /// already better before, and the local cleanup does more for nothing.
    static let goodEnough = 0.55

    /// How many passes in a row may fail to improve before it gives up.
    ///
    /// One, on measurement. Correcting turns out to rescue a bad drawing and
    /// spoil a good one: a weak first pass climbed 19% to 34% over four passes,
    /// but a 70% first pass came back 62% when the same model was asked to fix
    /// it, and 40% when a cheaper one was — that one bolted five new shapes on
    /// top of five that were already right.
    ///
    /// So a pass that fails to improve isn't a wobble to sit through, it's the
    /// signal that this drawing is done. Forgiving a second costs another call
    /// at trace prices to be told the same thing.
    static let patience = 1

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

        for pass in 1...max(1, tier.passes) {
            try Task.checkCancellation()
            used = pass
            progress(pass == 1 ? "Looking at the picture…" : "Pass \(pass) of \(tier.passes)…")

            // Only the newest turn carries pictures. The older ones are already
            // summarised by the drawing itself, and left in they'd blow the request
            // size for nothing.
            let asked = trimmed(messages)
            let turn: ModelTurn
            if pass == 1, tier.attempts > 1 {
                // The opening decides the whole structure and the cheap model is
                // streaky at it — the same prompt scored 22% one run and 41% the
                // next. Ask a few times at once and keep the best drawing rather
                // than the first one. They go together, so it costs the wait of
                // the slowest rather than the sum, and it lifts the floor, which
                // is where the variance actually hurts.
                turn = try await bestOpening(connector: connector, asking: asked,
                                             page: best, bounds: area, source: source,
                                             progress: progress)
            } else {
                let answer = try await connector.respond(to: asked, purpose: tier)
                turn = answer.turn
                if let model = answer.model, pass == 1 { progress("Drawing with \(model)") }
            }
            if !turn.say.isEmpty { say = turn.say }
            // The first pass writes the parts list and later passes correct
            // against it, so a replan only replaces it if it actually said
            // something. A pass that returns no plan is still working from the
            // one it wrote.
            if !turn.plan.isEmpty { plan = turn.plan }
            guard !turn.commands.isEmpty else { break }

            // Commands are told to correct what's there. A pass that only ever
            // ADDS has ignored that and redrawn the lot — and run onto the
            // previous drawing it lands a second copy of every shape on top of
            // the first, which is five Thumbs in the layer list and a score
            // that creeps up for the wrong reason.
            //
            // So a redraw is scored as a redraw: built on a clean page as well
            // as on the drawing so far, and whichever is actually closer wins.
            // One extra render, and no need to talk the model out of anything.
            var candidate = best
            _ = candidate.run(turn.commands)
            guard var attempt = Compare.render(candidate, bounds: area, matching: source) else { break }
            var score = Compare.inkAgreement(attempt, source)

            if turn.commands.allSatisfy({ if case .add = $0 { return true }; return false }) {
                var fresh = Page(name: "trace")
                _ = fresh.run(turn.commands)
                if let alone = Compare.render(fresh, bounds: area, matching: source) {
                    let onItsOwn = Compare.inkAgreement(alone, source)
                    if onItsOwn > score {
                        candidate = fresh
                        attempt = alone
                        score = onItsOwn
                    }
                }
            }

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
            // Good enough to stop asking. The cleanup that follows gains more
            // than another pass would, and never less than nothing.
            if bestScore >= goodEnough {
                progress("Good enough at \(Int((bestScore * 100).rounded()))% — tidying up rather than redrawing")
                break
            }
            if stale >= patience {
                progress("Stopped early — the last \(stale) passes didn't improve on \(Int((bestScore * 100).rounded()))%")
                break
            }
            guard pass < tier.passes else { break }

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

        // The model has put the right parts in roughly the wrong place, and
        // asking it to fix that makes it worse. Arithmetic is better at
        // coordinates than any of them, costs nothing, and cannot lose: only a
        // nudge that scores better than what it replaced is kept.
        try Task.checkCancellation()
        progress("Tidying up the placement…")
        let polished = await Task.detached(priority: .userInitiated) { [best] in
            Refine.polish(best, bounds: area, matching: source)
        }.value

        var outcome = Outcome(layers: best.layers, score: bestScore, passes: used,
                              say: say, scores: scores)
        if polished.score > bestScore {
            progress(String(format: "Tidied up: %.0f%% → %.0f%% in %d tries",
                            polished.startedAt * 100, polished.score * 100, polished.evaluations))
            outcome.tidied = Outcome.Tidied(layers: polished.page.layers,
                                            from: polished.startedAt, to: polished.score,
                                            tries: polished.evaluations)
            outcome.score = polished.score
        }
        return outcome
    }

    /// Which trace model to use, and with it how long to wait and how many
    /// openings to draw.
    ///
    /// `.trace` is Gemini Flash: eight seconds and a fifth of a cent, wildly
    /// streaky — six runs of one prompt scored 28, 33, 38, 55, 57 and 61 — so
    /// it draws five at once and keeps the best, which costs five cents and no
    /// extra waiting.
    ///
    /// `.traceBest` is Fable: four minutes and 88 cents. It draws better — 89%
    /// against 83% once the local tidy-up has run — but six points for
    /// eighty-seven cents and two and a half minutes is the wrong trade for
    /// something you sit and watch. One opening on that tier, because five
    /// would be $4.40 and no quicker than the slowest of them.
    ///
    /// One line, so switching tiers is one line.
    static let tier: ModelConnector.Purpose = .trace

    /// Draws the opening `attempts` times over and returns whichever scored
    /// best. A failed attempt is ignored rather than fatal; only every one
    /// failing is an error, and then it's the first error that gets thrown.
    private static func bestOpening(connector: ModelConnector, asking messages: [ModelConnector.Message],
                                    page: Page, bounds: CGRect, source: CGImage,
                                    progress: (String) -> Void) async throws -> ModelTurn {
        var results: [(turn: ModelTurn, score: Double)] = []
        var failure: Error?
        var model: String?

        await withTaskGroup(of: Result<(turn: ModelTurn, raw: String, model: String?), Error>.self) { group in
            for _ in 0..<tier.attempts {
                group.addTask {
                    do {
                        let answer = try await connector.respond(to: messages, purpose: tier)
                        return .success(answer)
                    } catch { return .failure(error) }
                }
            }
            for await outcome in group {
                switch outcome {
                case .failure(let error):
                    failure = failure ?? error
                case .success(let answer):
                    model = model ?? answer.model
                    let turn = answer.turn
                    guard !turn.commands.isEmpty else { continue }
                    var candidate = page
                    _ = candidate.run(turn.commands)
                    let score = Compare.render(candidate, bounds: bounds, matching: source)
                        .map { Compare.inkAgreement($0, source) } ?? 0
                    results.append((turn, score))
                }
            }
        }

        guard let winner = results.max(by: { $0.score < $1.score }) else {
            throw failure ?? Refusal.nothingDrawn
        }
        if let model { progress("Drawing with \(model)") }
        let all = results.map { "\(Int(($0.score * 100).rounded()))%" }.sorted().reversed().joined(separator: ", ")
        progress("Drew it \(results.count) time\(results.count == 1 ? "" : "s") — \(all) — keeping the best")
        return winner.turn
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
