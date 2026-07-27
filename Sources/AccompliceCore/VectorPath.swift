import CoreGraphics
import Foundation

// An editable view over a path.
//
// The model stores geometry as a baked CGPath — cheap to render, but you can't edit
// points you don't have. Rather than change the model (and with it the reader, the
// serializer and the SVG writer), VectorPath converts in both directions. The
// conversion is lossless because it only regroups the same numbers: a cubic's control
// points become the outgoing handle of one anchor and the incoming handle of the next.
//
// Deliberately NOT Figma's vector network — a graph of edges rather than a chain.
// That model is better, but SVG can't express it, and SVG is the engraving file. A
// graph would have to be decomposed back into paths on every export, which is exactly
// where fidelity bugs would hide. The interaction wins (bend, corner-first drawing,
// smart handles) don't need the graph; only branching and auto-regions do.

public enum CurveMode: Int, Sendable, Hashable, CaseIterable {
    case straight = 1     // no handles
    case mirrored = 2     // handles equal and opposite
    case asymmetric = 3   // collinear, independent lengths
    case disconnected = 4 // fully independent
}

public struct VectorPoint: Sendable {
    public var point: CGPoint
    /// Outgoing handle, absolute. Controls the segment TO the next point.
    public var curveFrom: CGPoint
    /// Incoming handle, absolute. Controls the segment FROM the previous point.
    public var curveTo: CGPoint
    public var hasCurveFrom: Bool
    public var hasCurveTo: Bool
    public var mode: CurveMode

    public init(_ p: CGPoint) {
        point = p; curveFrom = p; curveTo = p
        hasCurveFrom = false; hasCurveTo = false
        mode = .straight
    }

    public var isCorner: Bool { !hasCurveFrom && !hasCurveTo }

    /// Switches the point between Sketch's four kinds, reshaping the handles to suit.
    ///
    /// Going to straight drops the handles; coming back from it invents a pair along
    /// the direction the path was already heading, so the curve eases rather than
    /// snapping to something arbitrary.
    public mutating func convert(to newMode: CurveMode, previous: CGPoint?, next: CGPoint?) {
        switch newMode {
        case .straight:
            hasCurveFrom = false; hasCurveTo = false
            curveFrom = point; curveTo = point

        case .mirrored, .asymmetric, .disconnected:
            if isCorner {
                // No handles to work from: lay them along the chord through the point,
                // a third of the way to each neighbour, which is the usual smooth default.
                let before = previous ?? next ?? point
                let after = next ?? previous ?? point
                var dx = after.x - before.x, dy = after.y - before.y
                let len = hypot(dx, dy)
                if len < 0.0001 { dx = 1; dy = 0 }
                else { dx /= len; dy /= len }
                let outReach = hypot((next ?? point).x - point.x, (next ?? point).y - point.y) / 3
                let inReach = hypot((previous ?? point).x - point.x, (previous ?? point).y - point.y) / 3
                curveFrom = CGPoint(x: point.x + dx * outReach, y: point.y + dy * outReach)
                curveTo = CGPoint(x: point.x - dx * inReach, y: point.y - dy * inReach)
                hasCurveFrom = true; hasCurveTo = true
            }
            mode = newMode
            if newMode != .disconnected {
                // Re-run the constraint so the handles actually satisfy the new mode
                // rather than only doing so from the next drag onwards.
                setHandle(out: true, to: curveFrom)
            }
            return
        }
        mode = newMode
    }

    /// Moves the anchor, taking its handles along.
    public mutating func move(to p: CGPoint) {
        let d = CGPoint(x: p.x - point.x, y: p.y - point.y)
        point = p
        curveFrom = CGPoint(x: curveFrom.x + d.x, y: curveFrom.y + d.y)
        curveTo = CGPoint(x: curveTo.x + d.x, y: curveTo.y + d.y)
    }

    /// Sets one handle and brings the other along according to the mode.
    public mutating func setHandle(out: Bool, to p: CGPoint) {
        if out { curveFrom = p; hasCurveFrom = true } else { curveTo = p; hasCurveTo = true }
        guard mode == .mirrored || mode == .asymmetric else { return }
        let moved = out ? curveFrom : curveTo
        let dx = moved.x - point.x, dy = moved.y - point.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return }
        let other = out ? curveTo : curveFrom
        let otherLen = mode == .mirrored ? len : hypot(other.x - point.x, other.y - point.y)
        let opposite = CGPoint(x: point.x - dx / len * otherLen,
                               y: point.y - dy / len * otherLen)
        if out { curveTo = opposite; hasCurveTo = true } else { curveFrom = opposite; hasCurveFrom = true }
    }
}

public struct VectorPath: Sendable {
    public var points: [VectorPoint] = []
    public var closed = false

    public init(points: [VectorPoint] = [], closed: Bool = false) {
        self.points = points
        self.closed = closed
    }

    public var segmentCount: Int {
        guard points.count >= 2 else { return 0 }
        return closed ? points.count : points.count - 1
    }

    public func segment(_ i: Int) -> (a: VectorPoint, b: VectorPoint)? {
        guard i >= 0, i < segmentCount else { return nil }
        return (points[i], points[(i + 1) % points.count])
    }

    // MARK: - CGPath in

    /// Rebuilds editable points from a baked path.
    public init(cgPath: CGPath) {
        var pts: [VectorPoint] = []
        var isClosed = false
        cgPath.applyWithBlock { e in
            let p = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint:
                pts.append(VectorPoint(p[0]))
            case .addLineToPoint:
                pts.append(VectorPoint(p[0]))
            case .addCurveToPoint:
                if !pts.isEmpty {
                    pts[pts.count - 1].curveFrom = p[0]
                    pts[pts.count - 1].hasCurveFrom = true
                }
                var next = VectorPoint(p[2])
                next.curveTo = p[1]
                next.hasCurveTo = true
                pts.append(next)
            case .addQuadCurveToPoint:
                // Quadratic -> cubic: controls sit two-thirds of the way to the quad's.
                guard let last = pts.last else { break }
                let c1 = CGPoint(x: last.point.x + 2.0 / 3 * (p[0].x - last.point.x),
                                 y: last.point.y + 2.0 / 3 * (p[0].y - last.point.y))
                let c2 = CGPoint(x: p[1].x + 2.0 / 3 * (p[0].x - p[1].x),
                                 y: p[1].y + 2.0 / 3 * (p[0].y - p[1].y))
                pts[pts.count - 1].curveFrom = c1
                pts[pts.count - 1].hasCurveFrom = true
                var next = VectorPoint(p[1])
                next.curveTo = c2
                next.hasCurveTo = true
                pts.append(next)
            case .closeSubpath:
                isClosed = true
            @unknown default:
                break
            }
        }
        // A closed path repeats its start as the final lineTo; drop the duplicate.
        if isClosed, pts.count > 1, let f = pts.first, let l = pts.last,
           abs(f.point.x - l.point.x) < 0.001, abs(f.point.y - l.point.y) < 0.001 {
            if l.hasCurveTo { pts[0].curveTo = l.curveTo; pts[0].hasCurveTo = true }
            pts.removeLast()
        }
        for i in pts.indices { pts[i].mode = Self.inferMode(pts[i]) }
        self.init(points: pts, closed: isClosed)
    }

    private static func inferMode(_ p: VectorPoint) -> CurveMode {
        guard p.hasCurveFrom || p.hasCurveTo else { return .straight }
        guard p.hasCurveFrom && p.hasCurveTo else { return .disconnected }
        let a = CGPoint(x: p.curveFrom.x - p.point.x, y: p.curveFrom.y - p.point.y)
        let b = CGPoint(x: p.curveTo.x - p.point.x, y: p.curveTo.y - p.point.y)
        let la = hypot(a.x, a.y), lb = hypot(b.x, b.y)
        guard la > 0.0001, lb > 0.0001 else { return .disconnected }
        let cross = a.x * b.y - a.y * b.x
        let collinear = abs(cross) / (la * lb) < 0.02 && (a.x * b.x + a.y * b.y) < 0
        if !collinear { return .disconnected }
        return abs(la - lb) < 0.02 * max(la, lb) ? .mirrored : .asymmetric
    }

    // MARK: - CGPath out

    public func cgPath() -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 2 else {
            if let only = points.first { path.move(to: only.point); }
            return path.copy() ?? path
        }
        path.move(to: points[0].point)
        for i in 0..<segmentCount {
            let a = points[i], b = points[(i + 1) % points.count]
            let isClosingSegment = closed && i == segmentCount - 1
            if a.hasCurveFrom || b.hasCurveTo {
                path.addCurve(to: b.point,
                              control1: a.hasCurveFrom ? a.curveFrom : a.point,
                              control2: b.hasCurveTo ? b.curveTo : b.point)
            } else if !isClosingSegment {
                path.addLine(to: b.point)
            }
            // A straight closing segment is left to closeSubpath, which draws exactly
            // that line. Emitting it too would duplicate the edge on every round-trip.
        }
        if closed { path.closeSubpath() }
        return path.copy() ?? path
    }

    // MARK: - Editing

    /// Bends a segment so its midpoint lands on `target`, computing the handles.
    ///
    /// This is the interaction worth stealing from Figma: drag the curve itself rather
    /// than hunting a control point floating in empty space. For a cubic,
    /// B(0.5) = (P0 + 3·P1 + 3·P2 + P3) / 8, so shifting BOTH controls by d moves the
    /// midpoint by 0.75·d — hence the 4/3.
    public mutating func bend(segment i: Int, to target: CGPoint) {
        guard i >= 0, i < segmentCount else { return }
        let j = (i + 1) % points.count
        var a = points[i], b = points[j]
        if !a.hasCurveFrom { a.curveFrom = a.point; a.hasCurveFrom = true }
        if !b.hasCurveTo { b.curveTo = b.point; b.hasCurveTo = true }

        let mid = CGPoint(x: 0.125 * a.point.x + 0.375 * a.curveFrom.x
                             + 0.375 * b.curveTo.x + 0.125 * b.point.x,
                          y: 0.125 * a.point.y + 0.375 * a.curveFrom.y
                             + 0.375 * b.curveTo.y + 0.125 * b.point.y)
        let d = CGPoint(x: (target.x - mid.x) * 4 / 3, y: (target.y - mid.y) * 4 / 3)
        a.curveFrom = CGPoint(x: a.curveFrom.x + d.x, y: a.curveFrom.y + d.y)
        b.curveTo = CGPoint(x: b.curveTo.x + d.x, y: b.curveTo.y + d.y)
        if a.mode == .straight { a.mode = .disconnected }
        if b.mode == .straight { b.mode = .disconnected }
        points[i] = a
        points[j] = b
    }

    /// Removes a point, refitting the curve that spans the gap.
    ///
    /// Deleting a point used to hand the neighbours the deleted point's handles,
    /// which threw away the tangents and visibly flattened the curve. Instead the
    /// endpoints and their tangent *directions* are held fixed — a split never
    /// changes either — and the two handle lengths are solved by least squares
    /// against the curve being replaced. Undoing a split comes back exact, and any
    /// other deletion gets the closest single cubic there is.
    public mutating func removePoint(_ i: Int) {
        guard points.indices.contains(i), points.count > 1 else { return }
        let prev = (i - 1 + points.count) % points.count
        let next = (i + 1) % points.count

        if points.count > 2, closed || (i > 0 && i < points.count - 1),
           let (a, b) = refitAcross(prev: prev, gone: i, next: next) {
            points[prev].curveFrom = a
            points[prev].hasCurveFrom = true
            points[next].curveTo = b
            points[next].hasCurveTo = true
            if points[prev].mode == .straight { points[prev].mode = .disconnected }
            if points[next].mode == .straight { points[next].mode = .disconnected }
        }
        points.remove(at: i)
    }

    /// Least-squares fit of one cubic to the two segments either side of `gone`.
    ///
    /// Returns the two control points, or nil if the span is degenerate.
    private func refitAcross(prev: Int, gone: Int, next: Int) -> (CGPoint, CGPoint)? {
        let p0 = points[prev].point
        let p3 = points[next].point
        let mid = points[gone].point

        // Tangents stay as they are; only their lengths are unknown.
        func unit(_ from: CGPoint, _ to: CGPoint) -> CGPoint? {
            let d = CGPoint(x: to.x - from.x, y: to.y - from.y)
            let len = hypot(d.x, d.y)
            guard len > 0.0001 else { return nil }
            return CGPoint(x: d.x / len, y: d.y / len)
        }
        guard let t1 = unit(p0, points[prev].hasCurveFrom ? points[prev].curveFrom : mid),
              let t2 = unit(p3, points[next].hasCurveTo ? points[next].curveTo : mid)
        else { return nil }

        // Sample the curve we're replacing, and parameterise by chord length —
        // uniform parameterisation biases the fit toward whichever half is longer.
        var samples: [CGPoint] = []
        for (a, b) in [(points[prev], points[gone]), (points[gone], points[next])] {
            let steps = 24
            for s in 0...steps where !(s == 0 && !samples.isEmpty) {
                samples.append(Self.evaluate(a, b, CGFloat(s) / CGFloat(steps)))
            }
        }
        var us: [CGFloat] = [0]
        var total: CGFloat = 0
        for k in 1..<samples.count {
            total += hypot(samples[k].x - samples[k-1].x, samples[k].y - samples[k-1].y)
            us.append(total)
        }
        guard total > 0.0001 else { return nil }
        us = us.map { $0 / total }

        // Chord length is only an estimate of the parameter, and the error it leaves
        // is visible. Fit, then slide each sample along the fitted curve to where it
        // actually sits closest (Newton-Raphson), then fit again.
        var result: (CGPoint, CGPoint)?
        for pass in 0..<3 {
            guard let fit = solve(samples, us, p0, p3, t1, t2) else { break }
            result = fit
            guard pass < 2 else { break }
            us = reparameterise(samples, us, p0, fit.0, fit.1, p3)
        }
        return result
    }

    /// One least-squares solve for the two handle lengths, parameters held fixed.
    private func solve(_ samples: [CGPoint], _ us: [CGFloat],
                       _ p0: CGPoint, _ p3: CGPoint,
                       _ t1: CGPoint, _ t2: CGPoint) -> (CGPoint, CGPoint)? {
        var c00: CGFloat = 0, c01: CGFloat = 0, c11: CGFloat = 0
        var x0: CGFloat = 0, x1: CGFloat = 0
        for (k, u) in us.enumerated() {
            let mu = 1 - u
            let b0 = mu * mu * mu, b1 = 3 * mu * mu * u, b2 = 3 * mu * u * u, b3 = u * u * u
            let a1 = CGPoint(x: t1.x * b1, y: t1.y * b1)
            let a2 = CGPoint(x: t2.x * b2, y: t2.y * b2)
            c00 += a1.x * a1.x + a1.y * a1.y
            c01 += a1.x * a2.x + a1.y * a2.y
            c11 += a2.x * a2.x + a2.y * a2.y
            // What's left once the fixed endpoint terms are accounted for.
            let rest = CGPoint(x: samples[k].x - (b0 + b1) * p0.x - (b2 + b3) * p3.x,
                               y: samples[k].y - (b0 + b1) * p0.y - (b2 + b3) * p3.y)
            x0 += rest.x * a1.x + rest.y * a1.y
            x1 += rest.x * a2.x + rest.y * a2.y
        }
        let det = c00 * c11 - c01 * c01
        guard abs(det) > 1e-9 else { return nil }
        let alpha1 = (x0 * c11 - x1 * c01) / det
        let alpha2 = (c00 * x1 - c01 * x0) / det
        // A negative length would fold the handle back through the anchor.
        let span = hypot(p3.x - p0.x, p3.y - p0.y)
        let a1 = max(0, min(alpha1, span * 3))
        let a2 = max(0, min(alpha2, span * 3))
        return (CGPoint(x: p0.x + t1.x * a1, y: p0.y + t1.y * a1),
                CGPoint(x: p3.x + t2.x * a2, y: p3.y + t2.y * a2))
    }

    /// Moves each sample's parameter to where it really lies closest on the curve.
    private func reparameterise(_ samples: [CGPoint], _ us: [CGFloat],
                                _ p0: CGPoint, _ p1: CGPoint,
                                _ p2: CGPoint, _ p3: CGPoint) -> [CGFloat] {
        func at(_ u: CGFloat) -> CGPoint {
            let mu = 1 - u
            return CGPoint(x: mu*mu*mu*p0.x + 3*mu*mu*u*p1.x + 3*mu*u*u*p2.x + u*u*u*p3.x,
                           y: mu*mu*mu*p0.y + 3*mu*mu*u*p1.y + 3*mu*u*u*p2.y + u*u*u*p3.y)
        }
        func d1(_ u: CGFloat) -> CGPoint {
            let mu = 1 - u
            return CGPoint(x: 3*mu*mu*(p1.x-p0.x) + 6*mu*u*(p2.x-p1.x) + 3*u*u*(p3.x-p2.x),
                           y: 3*mu*mu*(p1.y-p0.y) + 6*mu*u*(p2.y-p1.y) + 3*u*u*(p3.y-p2.y))
        }
        func d2(_ u: CGFloat) -> CGPoint {
            CGPoint(x: 6*(1-u)*(p2.x - 2*p1.x + p0.x) + 6*u*(p3.x - 2*p2.x + p1.x),
                    y: 6*(1-u)*(p2.y - 2*p1.y + p0.y) + 6*u*(p3.y - 2*p2.y + p1.y))
        }
        return zip(samples, us).map { d, u in
            let q = at(u), q1 = d1(u), q2 = d2(u)
            let diff = CGPoint(x: q.x - d.x, y: q.y - d.y)
            let denom = q1.x*q1.x + q1.y*q1.y + diff.x*q2.x + diff.y*q2.y
            guard abs(denom) > 1e-9 else { return u }
            return max(0, min(1, u - (diff.x*q1.x + diff.y*q1.y) / denom))
        }
    }

    /// Inserts a point on a segment without changing the curve's shape.
    ///
    /// Splits the cubic with de Casteljau rather than dropping a point on the line
    /// and refitting: the two halves it produces are exactly the original curve, so
    /// adding a point somewhere to adjust it doesn't first nudge everything else.
    ///
    /// Returns the index of the new point.
    @discardableResult
    public mutating func insertPoint(onSegment i: Int, at t: CGFloat) -> Int? {
        guard i >= 0, i < segmentCount, let (a0, b0) = segment(i) else { return nil }
        let t = max(0.001, min(0.999, t))
        var a = a0, b = b0
        // Treat a straight segment as a cubic with controls at its ends, so the same
        // split works for both and a line stays a line.
        let p0 = a.point
        let p1 = a.hasCurveFrom ? a.curveFrom : a.point
        let p2 = b.hasCurveTo ? b.curveTo : b.point
        let p3 = b.point

        func lerp(_ u: CGPoint, _ v: CGPoint) -> CGPoint {
            CGPoint(x: u.x + (v.x - u.x) * t, y: u.y + (v.y - u.y) * t)
        }
        let q0 = lerp(p0, p1), q1 = lerp(p1, p2), q2 = lerp(p2, p3)
        let r0 = lerp(q0, q1), r1 = lerp(q1, q2)
        let mid = lerp(r0, r1)

        let wasStraight = !a.hasCurveFrom && !b.hasCurveTo
        var made = VectorPoint(mid)
        if wasStraight {
            made.mode = .straight
        } else {
            made.curveTo = r0; made.hasCurveTo = true
            made.curveFrom = r1; made.hasCurveFrom = true
            made.mode = .mirrored
            a.curveFrom = q0; a.hasCurveFrom = true
            b.curveTo = q2; b.hasCurveTo = true
        }

        let j = (i + 1) % points.count
        points[i] = a
        points[j] = b
        let at = i + 1
        points.insert(made, at: at)
        return at
    }

    /// Nearest segment to a point, for hit-testing the bend tool.
    public func closestSegment(to p: CGPoint, within tolerance: CGFloat)
        -> (index: Int, distance: CGFloat, t: CGFloat)? {
        var best: (Int, CGFloat, CGFloat)?
        for i in 0..<segmentCount {
            guard let (a, b) = segment(i) else { continue }
            // Two passes: coarse to find the neighbourhood, fine around it, so the
            // inserted point lands where the pointer is rather than on a 1/16 step.
            var lo: CGFloat = 0, hi: CGFloat = 1
            for _ in 0..<3 {
                let steps = 16
                for s in 0...steps {
                    let t = lo + (hi - lo) * CGFloat(s) / CGFloat(steps)
                    let q = Self.evaluate(a, b, t)
                    let d = hypot(q.x - p.x, q.y - p.y)
                    if d <= tolerance, best == nil || d < best!.1 { best = (i, d, t) }
                }
                guard let b2 = best, b2.0 == i else { break }
                let span = (hi - lo) / 16
                lo = max(0, b2.2 - span); hi = min(1, b2.2 + span)
            }
        }
        return best.map { (index: $0.0, distance: $0.1, t: $0.2) }
    }

    /// A point on a segment, at parameter t. Public so the canvas can show where
    /// an inserted point would land.
    public static func evaluate(_ a: VectorPoint, _ b: VectorPoint, _ t: CGFloat) -> CGPoint {
        let p0 = a.point
        let p1 = a.hasCurveFrom ? a.curveFrom : a.point
        let p2 = b.hasCurveTo ? b.curveTo : b.point
        let p3 = b.point
        let mt = 1 - t
        let w0 = mt * mt * mt, w1 = 3 * mt * mt * t, w2 = 3 * mt * t * t, w3 = t * t * t
        return CGPoint(x: w0 * p0.x + w1 * p1.x + w2 * p2.x + w3 * p3.x,
                       y: w0 * p0.y + w1 * p1.y + w2 * p2.y + w3 * p3.y)
    }
}
