import CoreGraphics
import Foundation

// Reduces the number of points in a path while holding it within a stated distance
// of the original.
//
// Traced or imported artwork routinely carries five to ten times the points it needs.
// The cost is real: every point is more to store, more to engrave, and more to fight
// with when you want to change the shape by hand.
//
// This is Schneider's curve fit — sample the path, fit one cubic to a run of samples,
// and if it strays further than the tolerance, split at the worst place and fit each
// half. What it is NOT is a language model looking at coordinates: which point to drop
// is a numerical question with a right answer, and arithmetic beats judgement here
// every time. The model's job is deciding what to simplify and how far, which is a
// question about intent — see `simplify` in DocumentCommand.

extension VectorPath {

    /// Refits the path so no part of it strays further than `tolerance` from the
    /// original, using as few points as that allows.
    ///
    /// Corners are kept. Rounding one off is not a smaller version of the shape, it's
    /// a different shape — and on an engraved coin it's the difference between a
    /// crisp point and a blob.
    public mutating func simplify(tolerance: CGFloat) {
        guard tolerance > 0, points.count > 2 else { return }

        // Sample densely enough that the fit sees the real curve, not a polygon.
        var samples: [CGPoint] = []
        var cornerAt: [Int] = []          // indices into samples that must be kept
        let steps = 12

        for i in 0..<segmentCount {
            guard let (a, b) = Self.pair(points, i, closed: closed) else { continue }
            if Self.turnsSharply(points, at: i, closed: closed) {
                cornerAt.append(samples.count)
            }
            for s in 0..<steps {
                samples.append(Self.evaluate(a, b, CGFloat(s) / CGFloat(steps)))
            }
        }
        guard samples.count > 3 else { return }
        // Close the sample run properly. Without this the last fitted anchor and the
        // first are joined by a curve nothing was ever fitted to, which on a circle
        // bulged a third of the radius off course.
        samples.append(closed ? samples[0] : points[points.count - 1].point)

        // Fit each run between corners on its own, so a corner stays a corner.
        var breaks = Set(cornerAt)
        breaks.insert(0)
        breaks.insert(samples.count - 1)
        let bounds = breaks.sorted()

        var out: [VectorPoint] = []
        for k in 0..<(bounds.count - 1) {
            let run = Array(samples[bounds[k]...bounds[k + 1]])
            guard run.count >= 2 else { continue }
            let fitted = Self.fit(run, tolerance: tolerance)
            // The runs share endpoints; keep one copy, merging the handles.
            if var last = out.popLast(), let first = fitted.first {
                last.curveFrom = first.curveFrom
                last.hasCurveFrom = first.hasCurveFrom
                last.mode = .disconnected
                out.append(last)
                out.append(contentsOf: fitted.dropFirst())
            } else {
                out.append(contentsOf: fitted)
            }
        }
        guard out.count >= 2, out.count < points.count else { return }

        if closed, var first = out.first, let last = out.last {
            // The closing segment's handles live on the first and last points.
            first.curveTo = last.curveTo
            first.hasCurveTo = last.hasCurveTo
            out[0] = first
            out.removeLast()
        }
        points = out
    }

    /// How many points this would come out at, without changing anything.
    public func simplified(tolerance: CGFloat) -> VectorPath {
        var copy = self
        copy.simplify(tolerance: tolerance)
        return copy
    }

    // MARK: - Fitting

    private static func pair(_ pts: [VectorPoint], _ i: Int, closed: Bool)
        -> (VectorPoint, VectorPoint)? {
        guard i >= 0, i < pts.count else { return nil }
        let j = i + 1
        if j < pts.count { return (pts[i], pts[j]) }
        return closed ? (pts[i], pts[0]) : nil
    }

    /// True where the path visibly kinks.
    ///
    /// Measured as the angle the path actually turns through, not by whether the point
    /// has handles. Traced artwork arrives as a polyline where NO point has handles —
    /// treating all of them as corners protects every one of them and simplifies
    /// nothing, which is exactly what this did at first. A 120-sided circle turns 3°
    /// per point; a square turns 90°.
    private static func turnsSharply(_ pts: [VectorPoint], at i: Int, closed: Bool) -> Bool {
        guard pts.indices.contains(i), pts.count > 2 else { return false }
        let p = pts[i]
        let prev = i == 0 ? (closed ? pts[pts.count - 1] : nil) : pts[i - 1]
        let next = i == pts.count - 1 ? (closed ? pts[0] : nil) : pts[i + 1]
        guard let prev, let next else { return false }

        // Prefer the handles when they exist — they are the true tangents.
        let inFrom = p.hasCurveTo ? p.curveTo : prev.point
        let outTo = p.hasCurveFrom ? p.curveFrom : next.point
        let incoming = CGPoint(x: p.point.x - inFrom.x, y: p.point.y - inFrom.y)
        let outgoing = CGPoint(x: outTo.x - p.point.x, y: outTo.y - p.point.y)
        let la = hypot(incoming.x, incoming.y), lb = hypot(outgoing.x, outgoing.y)
        guard la > 0.0001, lb > 0.0001 else { return false }
        let cosine = (incoming.x * outgoing.x + incoming.y * outgoing.y) / (la * lb)
        return cosine < 0.85        // about 32 degrees
    }

    /// Fits as few cubics as the tolerance allows to a run of samples.
    private static func fit(_ pts: [CGPoint], tolerance: CGFloat) -> [VectorPoint] {
        let t1 = tangent(pts, from: 0, to: min(3, pts.count - 1))
        let t2 = tangent(pts, from: pts.count - 1, to: max(0, pts.count - 4))
        var acc = Accumulator()
        fitRun(pts, t1, t2, tolerance, into: &acc, depth: 0)
        acc.finish(at: pts[pts.count - 1])
        return acc.points
    }

    /// Collects fitted cubics into a point list.
    ///
    /// A cubic's second control point belongs to the anchor at its END, not the one it
    /// was fitted from — so it has to be held until that anchor is appended. Dropping
    /// it left every interior point without an incoming handle, which turned a
    /// simplified circle into something 51 units out of round.
    private struct Accumulator {
        var points: [VectorPoint] = []
        private var pendingIncoming: CGPoint?

        mutating func add(anchor: CGPoint, outgoing: CGPoint, incoming: CGPoint) {
            var p = VectorPoint(anchor)
            if let waiting = pendingIncoming {
                p.curveTo = waiting
                p.hasCurveTo = true
            }
            p.curveFrom = outgoing
            p.hasCurveFrom = true
            p.mode = .disconnected
            points.append(p)
            pendingIncoming = incoming
        }

        mutating func finish(at anchor: CGPoint) {
            var p = VectorPoint(anchor)
            if let waiting = pendingIncoming {
                p.curveTo = waiting
                p.hasCurveTo = true
                p.mode = .disconnected
            }
            points.append(p)
        }
    }

    private static func fitRun(_ pts: [CGPoint], _ t1: CGPoint, _ t2: CGPoint,
                               _ tolerance: CGFloat, into acc: inout Accumulator,
                               depth: Int) {
        let first = pts[0], last = pts[pts.count - 1]

        // Too few samples to fit, or too deep to keep splitting.
        if pts.count < 4 || depth > 16 {
            let d = hypot(last.x - first.x, last.y - first.y) / 3
            acc.add(anchor: first,
                    outgoing: CGPoint(x: first.x + t1.x * d, y: first.y + t1.y * d),
                    incoming: CGPoint(x: last.x + t2.x * d, y: last.y + t2.y * d))
            return
        }

        var us = chordParameters(pts)
        for pass in 0..<4 {
            guard let fit = leastSquares(pts, us, first, last, t1, t2) else { break }
            let (error, worst) = maxDeviation(pts, us, first, fit.0, fit.1, last)
            if error <= tolerance {
                acc.add(anchor: first, outgoing: fit.0, incoming: fit.1)
                return
            }
            if pass == 3 {
                // Still too far off: split where it strays most and fit each side.
                let split = max(1, min(pts.count - 2, worst))
                let mid = centreTangent(pts, at: split)
                fitRun(Array(pts[0...split]), t1, mid, tolerance, into: &acc, depth: depth + 1)
                fitRun(Array(pts[split...]), CGPoint(x: -mid.x, y: -mid.y), t2,
                       tolerance, into: &acc, depth: depth + 1)
                return
            }
            us = reparameterised(pts, us, first, fit.0, fit.1, last)
        }
        // Fell through without converging: keep the best straight-ish cubic.
        let d = hypot(last.x - first.x, last.y - first.y) / 3
        acc.add(anchor: first,
                outgoing: CGPoint(x: first.x + t1.x * d, y: first.y + t1.y * d),
                incoming: CGPoint(x: last.x + t2.x * d, y: last.y + t2.y * d))
    }

    // MARK: - Numerics

    private static func tangent(_ pts: [CGPoint], from: Int, to: Int) -> CGPoint {
        guard pts.indices.contains(from), pts.indices.contains(to) else { return CGPoint(x: 1, y: 0) }
        let d = CGPoint(x: pts[to].x - pts[from].x, y: pts[to].y - pts[from].y)
        let len = hypot(d.x, d.y)
        guard len > 0.0001 else { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: d.x / len, y: d.y / len)
    }

    /// Tangent at a split, averaged from both sides so the two halves meet smoothly.
    private static func centreTangent(_ pts: [CGPoint], at i: Int) -> CGPoint {
        let before = CGPoint(x: pts[i - 1].x - pts[i].x, y: pts[i - 1].y - pts[i].y)
        let after = CGPoint(x: pts[i].x - pts[i + 1].x, y: pts[i].y - pts[i + 1].y)
        let d = CGPoint(x: (before.x + after.x) / 2, y: (before.y + after.y) / 2)
        let len = hypot(d.x, d.y)
        guard len > 0.0001 else { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: d.x / len, y: d.y / len)
    }

    private static func chordParameters(_ pts: [CGPoint]) -> [CGFloat] {
        var us: [CGFloat] = [0]
        var total: CGFloat = 0
        for i in 1..<pts.count {
            total += hypot(pts[i].x - pts[i-1].x, pts[i].y - pts[i-1].y)
            us.append(total)
        }
        guard total > 0.0001 else { return pts.indices.map { CGFloat($0) / CGFloat(pts.count - 1) } }
        return us.map { $0 / total }
    }

    static func bezier(_ u: CGFloat, _ p0: CGPoint, _ p1: CGPoint,
                       _ p2: CGPoint, _ p3: CGPoint) -> CGPoint {
        let mu = 1 - u
        return CGPoint(x: mu*mu*mu*p0.x + 3*mu*mu*u*p1.x + 3*mu*u*u*p2.x + u*u*u*p3.x,
                       y: mu*mu*mu*p0.y + 3*mu*mu*u*p1.y + 3*mu*u*u*p2.y + u*u*u*p3.y)
    }

    /// Worst distance from the samples to the fitted curve, and where it happens.
    private static func maxDeviation(_ pts: [CGPoint], _ us: [CGFloat],
                                     _ p0: CGPoint, _ p1: CGPoint,
                                     _ p2: CGPoint, _ p3: CGPoint) -> (CGFloat, Int) {
        var worst: CGFloat = 0
        var at = pts.count / 2
        for (i, u) in us.enumerated() {
            let q = bezier(u, p0, p1, p2, p3)
            let d = hypot(q.x - pts[i].x, q.y - pts[i].y)
            if d > worst { worst = d; at = i }
        }
        return (worst, at)
    }

    /// Solves for the two handle lengths with the endpoints and tangents held fixed.
    static func leastSquares(_ pts: [CGPoint], _ us: [CGFloat],
                             _ p0: CGPoint, _ p3: CGPoint,
                             _ t1: CGPoint, _ t2: CGPoint) -> (CGPoint, CGPoint)? {
        var c00: CGFloat = 0, c01: CGFloat = 0, c11: CGFloat = 0
        var x0: CGFloat = 0, x1: CGFloat = 0
        for (k, u) in us.enumerated() {
            let mu = 1 - u
            let b0 = mu*mu*mu, b1 = 3*mu*mu*u, b2 = 3*mu*u*u, b3 = u*u*u
            let a1 = CGPoint(x: t1.x * b1, y: t1.y * b1)
            let a2 = CGPoint(x: t2.x * b2, y: t2.y * b2)
            c00 += a1.x*a1.x + a1.y*a1.y
            c01 += a1.x*a2.x + a1.y*a2.y
            c11 += a2.x*a2.x + a2.y*a2.y
            let rest = CGPoint(x: pts[k].x - (b0 + b1) * p0.x - (b2 + b3) * p3.x,
                               y: pts[k].y - (b0 + b1) * p0.y - (b2 + b3) * p3.y)
            x0 += rest.x*a1.x + rest.y*a1.y
            x1 += rest.x*a2.x + rest.y*a2.y
        }
        let det = c00*c11 - c01*c01
        let span = hypot(p3.x - p0.x, p3.y - p0.y)
        var alpha1: CGFloat, alpha2: CGFloat
        if abs(det) > 1e-9 {
            alpha1 = (x0*c11 - x1*c01) / det
            alpha2 = (c00*x1 - c01*x0) / det
        } else {
            alpha1 = span / 3; alpha2 = span / 3
        }
        // A negative or wild length folds the handle back through its anchor.
        if alpha1 < 1e-6 || alpha2 < 1e-6 || alpha1 > span * 3 || alpha2 > span * 3 {
            alpha1 = span / 3; alpha2 = span / 3
        }
        return (CGPoint(x: p0.x + t1.x * alpha1, y: p0.y + t1.y * alpha1),
                CGPoint(x: p3.x + t2.x * alpha2, y: p3.y + t2.y * alpha2))
    }

    /// Slides each sample to where it really lies closest on the fitted curve.
    static func reparameterised(_ pts: [CGPoint], _ us: [CGFloat],
                                _ p0: CGPoint, _ p1: CGPoint,
                                _ p2: CGPoint, _ p3: CGPoint) -> [CGFloat] {
        zip(pts, us).map { d, u in
            let q = bezier(u, p0, p1, p2, p3)
            let mu = 1 - u
            let d1 = CGPoint(x: 3*mu*mu*(p1.x-p0.x) + 6*mu*u*(p2.x-p1.x) + 3*u*u*(p3.x-p2.x),
                             y: 3*mu*mu*(p1.y-p0.y) + 6*mu*u*(p2.y-p1.y) + 3*u*u*(p3.y-p2.y))
            let d2 = CGPoint(x: 6*mu*(p2.x - 2*p1.x + p0.x) + 6*u*(p3.x - 2*p2.x + p1.x),
                             y: 6*mu*(p2.y - 2*p1.y + p0.y) + 6*u*(p3.y - 2*p2.y + p1.y))
            let diff = CGPoint(x: q.x - d.x, y: q.y - d.y)
            let denom = d1.x*d1.x + d1.y*d1.y + diff.x*d2.x + diff.y*d2.y
            guard abs(denom) > 1e-9 else { return u }
            return max(0, min(1, u - (diff.x*d1.x + diff.y*d1.y) / denom))
        }
    }
}
