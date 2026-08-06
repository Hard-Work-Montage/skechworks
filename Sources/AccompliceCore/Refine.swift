import CoreGraphics
import Foundation

/// Nudging a traced drawing into place without asking a model anything.
///
/// Every model tested draws the right parts and puts them in roughly the wrong
/// place, and asking one to correct that makes it worse: a 70% drawing came
/// back 62% from the model that drew it and 40% from a cheaper one, which added
/// five new shapes on top of five that were already right. Coordinates are the
/// thing they are worst at and arithmetic is best at.
///
/// So this hill-climbs instead. Move a shape a few points, score it, keep it if
/// it helped, put it back if it didn't. No gradients — the score is a render,
/// which isn't differentiable — just a pattern search that tries both
/// directions on each knob and halves the step when a sweep stops paying.
///
/// It cannot make a drawing worse. Nothing is kept that didn't score better
/// than what it replaced, so the result is the input or an improvement on it.
public enum Refine {

    public struct Outcome: Sendable {
        public var page: Page
        public var score: Double
        public var startedAt: Double
        public var evaluations: Int
        public var gained: Double { score - startedAt }
    }

    /// What can be adjusted on one shape. Deliberately four knobs and not the
    /// control points: a finger in the wrong place is one number wrong, and a
    /// hundred point-nudges to say the same thing is a hundred times the search
    /// for a worse-conditioned answer.
    private enum Knob: CaseIterable {
        case x, y, size, weight

        /// Starting step, in page units except `size`, which is a ratio.
        var step: CGFloat {
            switch self {
            case .x, .y: return 12
            case .size: return 0.08
            case .weight: return 3
            }
        }
    }

    /// Hill-climb `page` towards `source`.
    ///
    /// - budget: wall-clock ceiling. The search stops mid-sweep when it's spent,
    ///   which is safe because every accepted move is already banked.
    public static func polish(_ page: Page, bounds: CGRect, matching source: CGImage,
                              budget: TimeInterval = 12,
                              progress: (String) -> Void = { _ in }) -> Outcome {
        let deadline = Date().addingTimeInterval(budget)
        var evaluations = 0

        // Search against a small copy. inkAgreement samples to 240 whatever it's
        // given, so a full-size render for every trial is detail nobody reads —
        // and the render is the whole cost of a trial.
        let reference = downscale(source, to: 240) ?? source

        func score(_ p: Page) -> Double {
            evaluations += 1
            guard let img = Compare.render(p, bounds: bounds, matching: reference) else { return 0 }
            return Compare.inkAgreement(img, reference)
        }

        var best = page
        var bestScore = score(best)
        let opening = bestScore

        // Only shapes move. A group's children carry their own frames, so the
        // indices here are into the flattened list of things that can be nudged.
        var targets = shapeIndices(in: best)
        guard !targets.isEmpty else {
            return Outcome(page: best, score: bestScore, startedAt: opening, evaluations: evaluations)
        }

        var scale: CGFloat = 1
        // Six halvings takes a 12-point step down to under a quarter of a point,
        // which is finer than the render can see.
        for round in 0..<6 {
            guard Date() < deadline else { break }
            var movedThisRound = false

            for path in targets {
                guard Date() < deadline else { break }
                for knob in Knob.allCases {
                    let step = knob.step * scale
                    // Both directions, and the winner is applied before moving on
                    // — so a later knob is judged against the shape as it now is.
                    for delta in [ step, -step ] {
                        guard let moved = apply(knob, delta, to: best, at: path) else { continue }
                        let s = score(moved)
                        if s > bestScore {
                            best = moved
                            bestScore = s
                            movedThisRound = true
                            break
                        }
                    }
                }
            }

            progress(String(format: "Tidying up: %.0f%%", bestScore * 100))
            // A sweep that changed nothing means the step is too coarse; a sweep
            // that changed something has probably not finished paying at this size.
            if !movedThisRound {
                scale /= 2
                if round >= 2, scale < 0.05 { break }
            }
            targets = shapeIndices(in: best)
        }

        return Outcome(page: best, score: bestScore, startedAt: opening, evaluations: evaluations)
    }

    // MARK: - Moving one shape

    /// Where every nudgeable shape lives, as a path of child indices.
    private static func shapeIndices(in page: Page) -> [[Int]] {
        var out: [[Int]] = []
        func walk(_ layers: [Layer], _ prefix: [Int]) {
            for (i, l) in layers.enumerated() {
                switch l.kind {
                case .group(let kids), .shapeGroup(let kids, _): walk(kids, prefix + [i])
                case .path: out.append(prefix + [i])
                default: continue
                }
            }
        }
        walk(page.layers, [])
        return out
    }

    private static func apply(_ knob: Knob, _ delta: CGFloat, to page: Page, at path: [Int]) -> Page? {
        var copy = page
        var changed = false
        modify(&copy.layers, path) { layer in
            switch knob {
            case .x:
                layer.frame.origin.x += delta
                changed = true
            case .y:
                layer.frame.origin.y += delta
                changed = true
            case .size:
                changed = resize(&layer, by: 1 + delta)
            case .weight:
                // Only means anything on a stroked shape, and thickness can't go
                // to nothing — a zero-width stroke is an invisible one.
                guard var border = layer.style.borders.first, border.thickness + delta >= 1 else { break }
                border.thickness += delta
                layer.style.borders[0] = border
                changed = true
            }
        }
        return changed ? copy : nil
    }

    /// Scales the outline about its own local origin, which is where the frame
    /// puts it — so the shape grows in place rather than sliding as it grows.
    private static func resize(_ layer: inout Layer, by factor: CGFloat) -> Bool {
        guard factor > 0.2, case .path(let p, let closed) = layer.kind else { return false }
        var t = CGAffineTransform(scaleX: factor, y: factor)
        guard let scaled = p.copy(using: &t) else { return false }
        let box = scaled.boundingBoxOfPath
        guard !box.isNull, box.width.isFinite, box.height.isFinite else { return false }
        layer.kind = .path(scaled, closed: closed)
        layer.frame.size = CGSize(width: max(1, box.maxX), height: max(1, box.maxY))
        return true
    }

    private static func modify(_ layers: inout [Layer], _ path: [Int], _ body: (inout Layer) -> Void) {
        guard let head = path.first, layers.indices.contains(head) else { return }
        if path.count == 1 { body(&layers[head]); return }
        let rest = Array(path.dropFirst())
        switch layers[head].kind {
        case .group(var kids):
            modify(&kids, rest, body)
            layers[head].kind = .group(kids)
        case .shapeGroup(var kids, let winding):
            modify(&kids, rest, body)
            layers[head].kind = .shapeGroup(kids, winding)
        default: return
        }
    }

    private static func downscale(_ image: CGImage, to side: Int) -> CGImage? {
        guard max(image.width, image.height) > side else { return image }
        let ratio = CGFloat(side) / CGFloat(max(image.width, image.height))
        let w = max(1, Int((CGFloat(image.width) * ratio).rounded()))
        let h = max(1, Int((CGFloat(image.height) * ratio).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
