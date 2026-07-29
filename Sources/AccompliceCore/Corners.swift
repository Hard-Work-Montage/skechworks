import CoreGraphics
import Foundation

// Rounding the corners of a shape.
//
// The model has no rectangle primitive — every shape is a resolved outline — so a
// corner radius can't be a parameter of a rect the way it is in Sketch. It's a property
// of the layer, applied to the outline on the way out through Compose. The stored path
// keeps its sharp corners, which is what makes the radius a number you can go back and
// change rather than a cut you can only undo.

/// How a corner rounds off.
public enum CornerStyle: Int, Sendable, Hashable, CaseIterable {
    /// A circular arc, tangent to both edges. What drawing programs have always done.
    case rounded = 0
    /// A squircle. The curvature ramps up along the straight instead of switching on at
    /// the tangent point, so there's no seam where the edge becomes the corner. It's the
    /// shape of an iOS icon, and it's what Sketch and Figma both call Smooth.
    case smooth = 1

    public var name: String {
        switch self {
        case .rounded: return "Rounded"
        case .smooth: return "Smooth"
        }
    }
}

public enum Corners {

    /// How much of the turn the ramps take, for `.smooth`.
    ///
    /// 0 leaves a plain arc and 1 leaves no arc at all. 0.6 is the iOS icon, and the
    /// number Figma's own iOS preset uses for the same control.
    public static let smoothing: CGFloat = 0.6

    /// The outline with every straight-to-straight corner taken off.
    ///
    /// Corners between curves are left alone: there's no obvious answer for what a
    /// radius means where the path is already turning, and Sketch doesn't offer one
    /// either.
    public static func round(_ path: CGPath, radius: CGFloat, style: CornerStyle) -> CGPath {
        guard radius > 0.001 else { return path }
        let subs = decompose(path)
        guard subs.contains(where: { $0.segments.count >= 2 }) else { return path }
        let out = CGMutablePath()
        var changed = false
        for sub in subs { changed = emit(sub, radius: radius, style: style, into: out) || changed }
        guard changed else { return path }
        return out.copy() ?? path
    }

    /// How many corners a radius would actually do something to.
    ///
    /// The inspector asks so it can leave the control out for a shape with no corners
    /// to round — a circle, or a trace that's all curves.
    public static func roundableCorners(in path: CGPath) -> Int {
        var n = 0
        for sub in decompose(path) {
            let segs = sub.segments
            guard segs.count >= 2 else { continue }
            let last = sub.closed ? segs.count : segs.count - 1
            for i in 0..<last where segs[i].isLine && segs[(i + 1) % segs.count].isLine {
                n += 1
            }
        }
        return n
    }

    // MARK: - Corner geometry

    /// The replacement for one corner: where the incoming edge now stops, where the
    /// outgoing edge now resumes, and what joins them.
    private struct Fillet {
        let enter: CGPoint
        let exit: CGPoint
        let pieces: [Piece]
    }

    private enum Piece {
        case curve(CGPoint, CGPoint, CGPoint)          // control 1, control 2, end
        case arc(centre: CGPoint, radius: CGFloat,
                 from: CGFloat, to: CGFloat, clockwise: Bool)
    }

    private static func fillet(previous: CGPoint, vertex v: CGPoint, next: CGPoint,
                               radius: CGFloat, style: CornerStyle) -> Fillet? {
        guard let a = unit(from: v, to: previous), let b = unit(from: v, to: next) else { return nil }
        let toPrevious = hypot(previous.x - v.x, previous.y - v.y)
        let toNext = hypot(next.x - v.x, next.y - v.y)

        let phi = acos(max(-1, min(1, a.x * b.x + a.y * b.y)))
        // Collinear, or doubled back on itself: there's no corner here to take off.
        guard phi > 0.02, phi < .pi - 0.02 else { return nil }
        let half = phi / 2

        // Never eat more than half an edge, or two corners sharing one would cross.
        let budget = min(toPrevious, toNext) / 2
        var s = (style == .smooth) ? smoothing : 0
        var r = radius
        let want = radius / tan(half)
        if want * (1 + s) > budget {
            // The radius is the number that was typed, so it gets the budget first and
            // the smoothing gives way. Past the point where even a plain arc won't fit,
            // the radius itself clamps — that's a shape as round as it can be.
            if want <= budget { s = budget / want - 1 } else { s = 0; r = budget * tan(half) }
        }
        guard r > 0.001 else { return nil }

        let t = r / tan(half)               // where a plain arc would touch each edge
        let reach = (1 + s) * t             // where a ramped one has to start instead
        guard let bisector = unit(CGPoint(x: a.x + b.x, y: a.y + b.y)) else { return nil }
        let span = r / sin(half)
        let centre = CGPoint(x: v.x + bisector.x * span, y: v.y + bisector.y * span)
        guard let dA = unit(from: centre, to: along(v, a, t)),
              let dB = unit(from: centre, to: along(v, b, t)) else { return nil }
        // Which way round the circle the path travels.
        let turn: CGFloat = (dA.x * dB.y - dA.y * dB.x) >= 0 ? 1 : -1

        let plain = Fillet(enter: along(v, a, t), exit: along(v, b, t),
                           pieces: [.arc(centre: centre, radius: r,
                                         from: atan2(dA.y, dA.x), to: atan2(dB.y, dB.x),
                                         clockwise: turn < 0)])
        guard style == .smooth else { return plain }

        // The turn is shared out: an arc in the middle, and a ramp either side of it
        // taking `alpha` each.
        let alpha = (.pi - phi) * s / 2
        guard sin(alpha) > 0.0001 else { return plain }
        let entryDir = rotate(dA, by: turn * alpha)
        let exitDir = rotate(dB, by: -turn * alpha)
        let arcStart = CGPoint(x: centre.x + entryDir.x * r, y: centre.y + entryDir.y * r)

        // Both of the ramp's control points sit on the straight edge, which is what
        // makes its curvature start at zero — that's the whole trick, and why this
        // doesn't have the seam a plain arc does. Where they sit decides the curvature
        // at the far end, and these two put it at exactly the arc's own 1/r, so there's
        // no jump there either.
        let off = CGPoint(x: arcStart.x - v.x, y: arcStart.y - v.y)
        let drop = abs(a.x * off.y - a.y * off.x)          // how far the arc starts off the edge
        let run = drop / sin(alpha)                        // and how far back along it that is
        let anchor = (a.x * off.x + a.y * off.y) + run * cos(alpha)
        let lead = 3 * run * run / (2 * r * sin(alpha))
        // No room to lay the ramp out in: a plain arc beats a bad squircle.
        guard anchor + lead < reach else { return plain }

        return Fillet(
            enter: along(v, a, reach),
            exit: along(v, b, reach),
            pieces: [
                .curve(along(v, a, anchor + lead), along(v, a, anchor), arcStart),
                .arc(centre: centre, radius: r,
                     from: atan2(entryDir.y, entryDir.x), to: atan2(exitDir.y, exitDir.x),
                     clockwise: turn < 0),
                .curve(along(v, b, anchor), along(v, b, anchor + lead), along(v, b, reach)),
            ])
    }

    // MARK: - Walking the path

    private struct Sub {
        var start: CGPoint
        var segments: [Segment] = []
        var closed = false
    }

    private enum Segment {
        case line(CGPoint)
        case curve(CGPoint, CGPoint, CGPoint)

        var end: CGPoint {
            switch self {
            case .line(let p): return p
            case .curve(_, _, let p): return p
            }
        }
        var isLine: Bool { if case .line = self { return true }; return false }
    }

    private static func decompose(_ path: CGPath) -> [Sub] {
        var subs: [Sub] = []
        var here: CGPoint = .zero
        path.applyWithBlock { e in
            let p = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint:
                subs.append(Sub(start: p[0]))
                here = p[0]
            case .addLineToPoint:
                if !subs.isEmpty { subs[subs.count - 1].segments.append(.line(p[0])) }
                here = p[0]
            case .addQuadCurveToPoint:
                // Raised to a cubic so there's one curve case to think about downstream.
                let c = p[0], to = p[1]
                let c1 = CGPoint(x: here.x + 2.0 / 3 * (c.x - here.x), y: here.y + 2.0 / 3 * (c.y - here.y))
                let c2 = CGPoint(x: to.x + 2.0 / 3 * (c.x - to.x), y: to.y + 2.0 / 3 * (c.y - to.y))
                if !subs.isEmpty { subs[subs.count - 1].segments.append(.curve(c1, c2, to)) }
                here = to
            case .addCurveToPoint:
                if !subs.isEmpty { subs[subs.count - 1].segments.append(.curve(p[0], p[1], p[2])) }
                here = p[2]
            case .closeSubpath:
                guard !subs.isEmpty else { break }
                // A close is a line home whenever the pen isn't already there. Making it
                // explicit means the join at the start point is a corner like any other.
                let start = subs[subs.count - 1].start
                if hypot(here.x - start.x, here.y - start.y) > 0.0001 {
                    subs[subs.count - 1].segments.append(.line(start))
                }
                subs[subs.count - 1].closed = true
                here = start
            @unknown default:
                break
            }
        }
        return subs
    }

    /// Writes one subpath into `out`, rounded. Returns whether anything changed.
    private static func emit(_ sub: Sub, radius: CGFloat, style: CornerStyle,
                             into out: CGMutablePath) -> Bool {
        let segs = sub.segments
        guard !segs.isEmpty else { return false }
        let n = segs.count

        // Keyed by the segment arriving at the corner. A corner only rounds when both
        // of its edges are straight.
        var fillets: [Int: Fillet] = [:]
        if n >= 2 {
            let last = sub.closed ? n : n - 1
            for i in 0..<last {
                let j = (i + 1) % n
                guard segs[i].isLine, segs[j].isLine else { continue }
                let from = i == 0 ? sub.start : segs[i - 1].end
                if let f = fillet(previous: from, vertex: segs[i].end, next: segs[j].end,
                                  radius: radius, style: style) {
                    fillets[i] = f
                }
            }
        }
        guard !fillets.isEmpty else {
            // Nothing to do, but it still has to be copied across.
            out.move(to: sub.start)
            for s in segs { append(s, to: out) }
            if sub.closed { out.closeSubpath() }
            return false
        }

        // On a closed subpath the start point is a corner too, and its fillet belongs to
        // the last segment — so the pen starts where that corner lets go, and the final
        // segment draws into it.
        out.move(to: (sub.closed ? fillets[n - 1]?.exit : nil) ?? sub.start)
        for i in 0..<n {
            switch segs[i] {
            case .line(let to):
                out.addLine(to: fillets[i]?.enter ?? to)
            case .curve(let c1, let c2, let to):
                out.addCurve(to: to, control1: c1, control2: c2)
            }
            if let f = fillets[i] {
                for piece in f.pieces {
                    switch piece {
                    case .curve(let c1, let c2, let end):
                        out.addCurve(to: end, control1: c1, control2: c2)
                    case .arc(let centre, let r, let from, let to, let cw):
                        out.addArc(center: centre, radius: r, startAngle: from,
                                   endAngle: to, clockwise: cw)
                    }
                }
            }
        }
        if sub.closed { out.closeSubpath() }
        return true
    }

    private static func append(_ s: Segment, to path: CGMutablePath) {
        switch s {
        case .line(let p): path.addLine(to: p)
        case .curve(let c1, let c2, let p): path.addCurve(to: p, control1: c1, control2: c2)
        }
    }

    // MARK: - Small vector helpers

    private static func unit(_ v: CGPoint) -> CGPoint? {
        let len = hypot(v.x, v.y)
        guard len > 0.0001 else { return nil }
        return CGPoint(x: v.x / len, y: v.y / len)
    }

    private static func unit(from: CGPoint, to: CGPoint) -> CGPoint? {
        unit(CGPoint(x: to.x - from.x, y: to.y - from.y))
    }

    private static func along(_ from: CGPoint, _ direction: CGPoint, _ distance: CGFloat) -> CGPoint {
        CGPoint(x: from.x + direction.x * distance, y: from.y + direction.y * distance)
    }

    private static func rotate(_ v: CGPoint, by angle: CGFloat) -> CGPoint {
        let c = cos(angle), s = sin(angle)
        return CGPoint(x: v.x * c - v.y * s, y: v.x * s + v.y * c)
    }
}
