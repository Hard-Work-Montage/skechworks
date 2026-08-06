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
                              budget: TimeInterval = 30,
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

        // How big each shape started. A misplaced shape scores better by
        // VANISHING — ink overlap counts wrong ink against you, so shrinking a
        // stem that isn't quite on the stem raises the ratio, and shrinking it
        // to nothing raises it most. The search found that and quietly deleted
        // the stems off a drawing while reporting an improvement. Sizes are
        // held near what the model drew for the same reason points are.
        var born: [String: CGSize] = [:]
        func remember(_ layers: [Layer]) {
            for l in layers {
                switch l.kind {
                case .group(let kids), .shapeGroup(let kids, _): remember(kids)
                case .path: born[l.id] = l.frame.size
                default: continue
                }
            }
        }
        remember(best.layers)

        // Only shapes move. A group's children carry their own frames, so the
        // indices here are into the flattened list of things that can be nudged.
        var targets = shapeIndices(in: best)
        guard !targets.isEmpty else {
            return Outcome(page: best, score: bestScore, startedAt: opening, evaluations: evaluations)
        }

      while Date() < deadline {
        let roundStart = bestScore
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
                        guard let moved = apply(knob, delta, to: best, at: path, born: born) else { continue }
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

        // Whole shapes can only be slid, grown and thickened. Once that stops
        // paying, what's left is the outline's own shape — a corner cut across,
        // a curve bowing the wrong way — and only the points can fix that.
        if Date() < deadline {
            let paths = shapeIndices(in: best)
            for (n, path) in paths.enumerated() {
                guard Date() < deadline else { break }
                // Twenty seconds of silence looks like a hang, so it counts out
                // loud. Shapes, not percentages: the score barely moves on any
                // single point and a number that doesn't move reads as stuck.
                progress("Tidying up shape \(n + 1) of \(paths.count)…")
                // Where the model put them. Corrections are measured from here,
                // not from wherever the search has wandered to.
                let anchors = anchorPositions(of: best, at: path)
                guard anchors.count > 1, anchors.count <= 64 else { continue }
                for index in 0..<anchors.count {
                    guard Date() < deadline else { break }
                    var step: CGFloat = 4
                    while step >= 0.5 {
                        var moved = false
                        for delta in [ CGPoint(x: step, y: 0), CGPoint(x: -step, y: 0),
                                       CGPoint(x: 0, y: step), CGPoint(x: 0, y: -step) ] {
                            guard let nudged = nudge(point: index, by: delta, in: best, at: path,
                                                     within: drift, of: anchors[index]) else { continue }
                            let s = score(nudged)
                            if s > bestScore {
                                best = nudged
                                bestScore = s
                                moved = true
                                break
                            }
                        }
                        if !moved { step /= 2 }
                    }
                }
            }
            progress(String(format: "Tidying up: %.0f%%", bestScore * 100))
        }

        // Moving points changes where the whole shape wants to sit, and moving
        // the shape changes which points are wrong — so the two stages feed each
        // other and one pass of each leaves real gains behind. Measured: a
        // second run over a finished drawing found another five points. Round
        // trips until neither stage pays.
        if bestScore <= roundStart + 0.001 { break }
      }

        return Outcome(page: best, score: bestScore, startedAt: opening, evaluations: evaluations)
    }

    // MARK: - Moving one point

    /// How far one anchor may end up from where the model drew it.
    ///
    /// Points moved freely score better and look worse. Ink overlap rewards
    /// catching a few more pixels and says nothing at all about a straight line
    /// staying straight — so a stem grows a step in it, a beam picks up a
    /// jagged end, and a drawing that read as drawn starts reading as wobbled.
    ///
    /// The model's shape is coherent even when it's in the wrong place. Whole
    /// shapes still move as far as they like, because sliding one doesn't
    /// deform it; only the points are kept on a short lead, enough to take up
    /// slack and not enough to shred the outline.
    private static let drift: CGFloat = 3

    /// Whether moving `index` to `landing` leaves a straight run straight.
    ///
    /// Judged on the run as it stands, so a shape the model drew with a bend
    /// there keeps its freedom to move — only a corner that IS square, or an
    /// edge that IS straight, is defended.
    private static func keepsItsLine(_ path: VectorPath, index: Int, moving landing: CGPoint) -> Bool {
        let n = path.points.count
        guard n >= 3 else { return true }
        // Each neighbouring triple that includes this point.
        for offset in -1...1 {
            let mid = index + offset
            guard path.closed || (mid > 0 && mid < n - 1) else { continue }
            let a = path.points[((mid - 1) % n + n) % n].point
            let c = path.points[(mid + 1) % n].point
            let bWas = path.points[((mid % n) + n) % n].point
            let bNow = (mid % n + n) % n == index ? landing : bWas
            let wasStraight = bend(a, bWas, c)
            guard wasStraight < 0.08 else { continue }   // it was a corner; leave it be
            if bend(a, bNow, c) > 0.08 { return false }
        }
        return true
    }

    /// How far a point sits off the line between its neighbours, as a fraction
    /// of that line's length. Scale-free, so it means the same on a long stem
    /// and a short one.
    private static func bend(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let dx = c.x - a.x, dy = c.y - a.y
        let span = (dx * dx + dy * dy).squareRoot()
        guard span > 0.001 else { return 0 }
        return abs((b.x - a.x) * dy - (b.y - a.y) * dx) / (span * span)
    }

    private static func anchorPositions(of page: Page, at path: [Int]) -> [CGPoint] {
        var out: [CGPoint] = []
        var copy = page
        modify(&copy.layers, path) { layer in
            guard case .path(let p, _) = layer.kind else { return }
            out = VectorPath(cgPath: p).points.map(\.point)
        }
        return out
    }

    /// Moves one anchor and the handles either side of it, so the curve follows
    /// rather than kinking at the point that moved.
    private static func nudge(point index: Int, by delta: CGPoint,
                              in page: Page, at path: [Int],
                              within limit: CGFloat, of home: CGPoint) -> Page? {
        var copy = page
        var changed = false
        modify(&copy.layers, path) { layer in
            guard case .path(let cg, let closed) = layer.kind else { return }
            var vector = VectorPath(cgPath: cg)
            guard vector.points.indices.contains(index) else { return }
            // Refuse the move rather than clamping it: a clamped move that keeps
            // being proposed is a loop that never settles.
            let landing = CGPoint(x: vector.points[index].point.x + delta.x,
                                  y: vector.points[index].point.y + delta.y)
            guard abs(landing.x - home.x) <= limit, abs(landing.y - home.y) <= limit else { return }
            // A point sitting on a straight run has to stay on it. This is the
            // damage you can see: ink overlap will happily buy three pixels by
            // putting a step in the middle of a stem, because nothing in the
            // score knows a straight line is worth anything. Curves are left
            // alone — they were never straight, so there's nothing to break.
            guard keepsItsLine(vector, index: index, moving: landing) else { return }
            vector.points[index].point.x += delta.x
            vector.points[index].point.y += delta.y
            vector.points[index].curveFrom.x += delta.x
            vector.points[index].curveFrom.y += delta.y
            vector.points[index].curveTo.x += delta.x
            vector.points[index].curveTo.y += delta.y
            let rebuilt = vector.cgPath()
            let box = rebuilt.boundingBoxOfPath
            guard !box.isNull, !box.isInfinite, box.minX.isFinite, box.minY.isFinite,
                  abs(box.maxX) < 1e6, abs(box.maxY) < 1e6 else { return }
            layer.kind = .path(rebuilt, closed: closed)
            changed = true
        }
        return changed ? copy : nil
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

    private static func apply(_ knob: Knob, _ delta: CGFloat, to page: Page, at path: [Int],
                              born: [String: CGSize]) -> Page? {
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
                // Half to double what it was drawn as. Enough to fix a shape
                // that came out too small, not enough to make one disappear.
                guard let start = born[layer.id] else { break }
                var trial = layer
                guard resize(&trial, by: 1 + delta) else { break }
                let w = trial.frame.width / max(1, start.width)
                let h = trial.frame.height / max(1, start.height)
                guard w > 0.5, w < 2, h > 0.5, h < 2 else { break }
                layer = trial
                changed = true
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
        // Every corner, not just the extent. A box can have a finite width and
        // still sit at infinity, and the frame is built from maxX/maxY — one
        // non-finite number there poisons the layer, and the change detector
        // that reads it on every subsequent edit used to trap on it.
        let box = scaled.boundingBoxOfPath
        guard !box.isNull, !box.isInfinite,
              box.minX.isFinite, box.minY.isFinite,
              abs(box.maxX) < 1e6, abs(box.maxY) < 1e6 else { return false }
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
