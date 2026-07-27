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

public enum CurveMode: Int, Sendable {
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

    /// Removes a point, leaving the neighbouring curve as intact as possible rather
    /// than collapsing it to a straight line.
    public mutating func removePoint(_ i: Int) {
        guard points.indices.contains(i), points.count > 1 else { return }
        let prev = (i - 1 + points.count) % points.count
        let next = (i + 1) % points.count
        if points.count > 2, closed || (i > 0 && i < points.count - 1) {
            if points[i].hasCurveTo { points[prev].curveFrom = points[i].curveTo; points[prev].hasCurveFrom = true }
            if points[i].hasCurveFrom { points[next].curveTo = points[i].curveFrom; points[next].hasCurveTo = true }
        }
        points.remove(at: i)
    }

    /// Nearest segment to a point, for hit-testing the bend tool.
    public func closestSegment(to p: CGPoint, within tolerance: CGFloat) -> (index: Int, distance: CGFloat)? {
        var best: (Int, CGFloat)?
        for i in 0..<segmentCount {
            guard let (a, b) = segment(i) else { continue }
            let steps = 16
            for s in 0...steps {
                let t = CGFloat(s) / CGFloat(steps)
                let q = Self.evaluate(a, b, t)
                let d = hypot(q.x - p.x, q.y - p.y)
                if d <= tolerance, best == nil || d < best!.1 { best = (i, d) }
            }
        }
        return best.map { (index: $0.0, distance: $0.1) }
    }

    static func evaluate(_ a: VectorPoint, _ b: VectorPoint, _ t: CGFloat) -> CGPoint {
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
