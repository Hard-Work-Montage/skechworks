import CoreGraphics
import Foundation

/// Four-corner perspective for paths.
///
/// A bitmap gets this from Core Image, which projects pixels and hands back
/// pixels. A path can't go that way: there are no pixels, and the thing being
/// projected is geometry that has to come out the other side still being
/// geometry. So the map is solved here.
///
/// The map is a homography — eight numbers rather than the six an affine
/// transform carries, and the two extra are exactly what lets one side of a
/// shape come out shorter than the other. That is the whole difference between
/// this and skew: a shear takes a rectangle to a parallelogram and can do
/// nothing else, while this takes it to any quadrilateral you like.
public enum Perspective {

    /// The map from the unit square to `quad`, or nil when the quad is
    /// degenerate — three corners in a line has no inverse and no meaning.
    ///
    /// Corners run nw, ne, se, sw, the same order the bitmap warp stores them,
    /// so a quad can move between the two without being reshuffled.
    public static func map(toUnitQuad quad: [CGPoint]) -> ((CGPoint) -> CGPoint)? {
        guard quad.count == 4 else { return nil }
        let (p0, p1, p2, p3) = (quad[0], quad[1], quad[2], quad[3])

        // Heckbert's solution for the square-to-quad case, which is the only one
        // needed: the source is always the unit square of the layer's frame.
        let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x, dx3 = p0.x - p1.x + p2.x - p3.x
        let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y, dy3 = p0.y - p1.y + p2.y - p3.y

        var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat
        var e: CGFloat, f: CGFloat, g: CGFloat, h: CGFloat

        if abs(dx3) < 1e-12, abs(dy3) < 1e-12 {
            // The quad is a parallelogram, so no perspective term is needed and
            // the general formula's denominator would be doing nothing.
            a = p1.x - p0.x; b = p2.x - p1.x; c = p0.x
            d = p1.y - p0.y; e = p2.y - p1.y; f = p0.y
            g = 0; h = 0
        } else {
            let den = dx1 * dy2 - dy1 * dx2
            guard abs(den) > 1e-12 else { return nil }
            g = (dx3 * dy2 - dy3 * dx2) / den
            h = (dx1 * dy3 - dy1 * dx3) / den
            a = p1.x - p0.x + g * p1.x
            b = p3.x - p0.x + h * p3.x
            c = p0.x
            d = p1.y - p0.y + g * p1.y
            e = p3.y - p0.y + h * p3.y
            f = p0.y
        }

        // Three corners in a line gives a matrix with no inverse: the map exists
        // on paper and collapses the square onto a line. The elimination above
        // doesn't notice — its own denominator is perfectly healthy — so the
        // determinant is what has to be asked.
        let det = a * (e - f * h) - b * (d - f * g) + c * (d * h - e * g)
        guard abs(det) > 1e-9 else { return nil }

        return { p in
            let w = g * p.x + h * p.y + 1
            // Behind the horizon. Nothing sensible is on the far side of it, so
            // the point stays where it was rather than being flung to infinity.
            guard abs(w) > 1e-9 else { return p }
            return CGPoint(x: (a * p.x + b * p.y + c) / w, y: (d * p.x + e * p.y + f) / w)
        }
    }

    /// How far a chopped curve may stray from the true projected one.
    ///
    /// A straight line needs none of this — a homography takes lines to lines,
    /// exactly — so only curves pay. A cubic doesn't survive the trip: its image
    /// is a RATIONAL cubic, and mapping the control points of an ordinary one
    /// ignores the weights entirely. Cutting it up first shrinks the error,
    /// because a short enough piece has almost no weight variation left in it.
    ///
    /// Chopping every curve a fixed twelve times was the first version, and it
    /// spent the same 48 segments on a 200pt oval whether it had been leaned a
    /// degree or bent double. So the curve is asked instead of told: each piece
    /// is compared against the point the projection really puts at its middle,
    /// and split only when it misses by more than this.
    ///
    /// The number is a budget for that midpoint check, which overstates the real
    /// error by roughly ten times — it asks about the worst place on the piece,
    /// not the average. Measured against a densely projected oval:
    ///
    ///     lean      segments   worst it actually strays
    ///     gentle       8            0.10pt
    ///     strong      20            0.05pt
    ///     severe      28            0.05pt
    ///
    /// A tenth of a point is under half a pixel at 400% zoom, for between two
    /// and six times fewer segments than the fixed twelve managed. The hard
    /// warps come out BETTER as well as smaller, because the pieces land where
    /// the bend is instead of being spread evenly along a curve that mostly
    /// didn't need them.
    public static let tolerance: CGFloat = 0.5

    /// Where splitting stops regardless. Six halvings is 64 pieces from one
    /// curve, which no honest warp reaches — it's here so a quad aimed at the
    /// horizon can't spin.
    public static let maxDepth = 6

    /// `path` with the perspective baked in, both in the layer's own space.
    ///
    /// `size` is the frame the corners are quoted against: they're in unit
    /// coordinates, so 0,0 is the frame's top left and 1,1 its bottom right, and
    /// dragging one past that is how a shape grows beyond its own box.
    /// More segments than any drawing has a reason to hold.
    ///
    /// Belt and braces after a real one. Warping a shape used to chop every
    /// curve twelve times whatever the lean, and each fresh drag took the
    /// already-chopped path as its starting point — so four warps of a 261-curve
    /// union came to 261 x 12^4, or 5.4 million segments and 217MB of path text
    /// in a comic. Splitting only where the projection needs it stops the
    /// multiplying, because a piece that is already fine passes the check and is
    /// left alone. This is here in case some other route ever finds its way back
    /// to the same place: a warp that would produce this much is refused, and
    /// refusing leaves the shape exactly as it was.
    public static let segmentCeiling = 100_000

    public static func warp(_ path: CGPath, size: CGSize, corners: [CGPoint],
                            tolerance: CGFloat = Perspective.tolerance) -> CGPath? {
        guard size.width > 0, size.height > 0, let project = map(toUnitQuad: corners) else { return nil }

        // In and out of unit space around the projection, so the caller works in
        // the same coordinates it draws in.
        func send(_ p: CGPoint) -> CGPoint {
            let unit = project(CGPoint(x: p.x / size.width, y: p.y / size.height))
            return CGPoint(x: unit.x * size.width, y: unit.y * size.height)
        }

        let out = CGMutablePath()
        var here = CGPoint.zero
        var start = CGPoint.zero
        var emitted = 0
        var overrun = false
        path.applyWithBlock { element in
            let pts = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                here = pts[0]; start = pts[0]
                out.move(to: send(pts[0]))
            case .addLineToPoint:
                here = pts[0]
                out.addLine(to: send(pts[0]))
            case .addQuadCurveToPoint:
                // As a cubic, so there's one subdivision routine rather than two.
                let c1 = CGPoint(x: here.x + 2.0 / 3 * (pts[0].x - here.x),
                                 y: here.y + 2.0 / 3 * (pts[0].y - here.y))
                let c2 = CGPoint(x: pts[1].x + 2.0 / 3 * (pts[0].x - pts[1].x),
                                 y: pts[1].y + 2.0 / 3 * (pts[0].y - pts[1].y))
                emit(cubic: (here, c1, c2, pts[1]), tolerance: tolerance,
                     into: out, send: send, emitted: &emitted, overrun: &overrun)
                here = pts[1]
            case .addCurveToPoint:
                emit(cubic: (here, pts[0], pts[1], pts[2]), tolerance: tolerance,
                     into: out, send: send, emitted: &emitted, overrun: &overrun)
                here = pts[2]
            case .closeSubpath:
                out.closeSubpath()
                here = start
            @unknown default:
                break
            }
        }
        return (out.isEmpty || overrun) ? nil : out
    }

    /// Projects a cubic, splitting it only where the projection needs it.
    private static func emit(cubic c: (CGPoint, CGPoint, CGPoint, CGPoint), tolerance: CGFloat,
                             depth: Int = 0, into out: CGMutablePath, send: (CGPoint) -> CGPoint,
                             emitted: inout Int, overrun: inout Bool) {
        if overrun { return }
        let mapped = (send(c.0), send(c.1), send(c.2), send(c.3))
        // Where the projection really puts the middle of this curve, against
        // where the mapped control points say it is. The gap between those two
        // IS the error being made, so it's the thing worth measuring.
        let truth = send(at(0.5, c))
        let guess = at(0.5, mapped)
        if depth >= maxDepth || hypot(truth.x - guess.x, truth.y - guess.y) <= tolerance {
            out.addCurve(to: mapped.3, control1: mapped.1, control2: mapped.2)
            emitted += 1
            if emitted > segmentCeiling { overrun = true }
            return
        }
        let (left, right) = split(c, at: 0.5)
        emit(cubic: left, tolerance: tolerance, depth: depth + 1, into: out, send: send,
             emitted: &emitted, overrun: &overrun)
        emit(cubic: right, tolerance: tolerance, depth: depth + 1, into: out, send: send,
             emitted: &emitted, overrun: &overrun)
    }

    /// A cubic at t.
    private static func at(_ t: CGFloat, _ c: (CGPoint, CGPoint, CGPoint, CGPoint)) -> CGPoint {
        let s = 1 - t
        return CGPoint(
            x: s*s*s*c.0.x + 3*s*s*t*c.1.x + 3*s*t*t*c.2.x + t*t*t*c.3.x,
            y: s*s*s*c.0.y + 3*s*s*t*c.1.y + 3*s*t*t*c.2.y + t*t*t*c.3.y)
    }

    /// de Casteljau, giving both halves.
    private static func split(_ c: (CGPoint, CGPoint, CGPoint, CGPoint), at t: CGFloat)
        -> ((CGPoint, CGPoint, CGPoint, CGPoint), (CGPoint, CGPoint, CGPoint, CGPoint)) {
        func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        let ab = mix(c.0, c.1), bc = mix(c.1, c.2), cd = mix(c.2, c.3)
        let abc = mix(ab, bc), bcd = mix(bc, cd)
        let mid = mix(abc, bcd)
        return ((c.0, ab, abc, mid), (mid, bcd, cd, c.3))
    }
}

extension Layer {
    /// Bakes a four-corner perspective into this layer's own geometry.
    ///
    /// Baked rather than kept live, which is the deliberate trade. A bitmap's
    /// distort is a lens: the picture is untouched and the corners can be moved
    /// again or dropped entirely. This rewrites the path, so undo is the only
    /// way back and the curves stay chopped. In exchange nothing downstream has
    /// to learn anything — the renderer, hit-testing, boolean ops and the SVG
    /// writer all see an ordinary path, and a perspective-warped shape exports
    /// as real geometry rather than as a picture of itself.
    ///
    /// Corners are unit coordinates of the frame, nw ne se sw.
    @discardableResult
    public mutating func applyPerspective(corners: [CGPoint]) -> Bool {
        guard canSkew, corners.count == 4,
              let source = Compose.resolvedPath(self),
              let warped = Perspective.warp(source, size: frame.size, corners: corners)
        else { return false }
        let box = warped.boundingBoxOfPath
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return false }

        var closed = true
        if case .path(_, let wasClosed) = kind { closed = wasClosed }
        // Through the layer's own transform, so a shape that is flipped or
        // rotated doesn't jump when its frame changes size.
        frame = Compose.reframed(self, localBounds: box)
        kind = .path(warped.transformed(by: CGAffineTransform(translationX: -box.minX,
                                                              y: -box.minY)), closed: closed)
        // resolvedPath already turned radii and boolean children into outline, so
        // leaving either set would apply them a second time.
        cornerRadius = 0
        cornerRadii = []
        curveModes = []
        return true
    }
}
