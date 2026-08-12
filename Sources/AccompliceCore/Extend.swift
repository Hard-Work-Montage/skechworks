import CoreGraphics
import Foundation

/// Growing a picture outward and drawing the new part from what was already
/// there.
///
/// The sibling of `Heal`, and deliberately not the same algorithm. Remove puts
/// a hole in the middle of a picture, where every side of the hole has real
/// pixels to settle against, and diffusion is exactly right. An extension has
/// real pixels on ONE side and the edge of the canvas on the other three, and
/// diffusion there pulls the new area toward the emptiness around it — the
/// first version of this came back half-transparent, which in a premultiplied
/// bitmap reads as the right colour at half brightness, and looks like a colour
/// bug rather than an alpha one.
///
/// So the new area is drawn by carrying the edge outward instead. On flat
/// artwork that is not an approximation: a band of colour running off the edge
/// of the picture continues as that band, and an outline crossing the edge
/// continues as that outline. It is also instant, offline and free.
///
/// Where it stops being true is a picture with somewhere to go — a face, a
/// horizon, a hand. Carried outward those give streaks, so the answer is graded
/// before it is offered: a strip of the REAL picture the same shape as the one
/// being invented is continued the same way and checked against the truth that
/// is already sitting there.
public enum Extend {

    public struct Result {
        public let image: CGImage
        /// Where the old picture sits inside the new one, in pixels. The layer
        /// has to move by this much for the artwork to stay where it looked.
        public let offset: CGPoint
        /// Average channel error, 0–255, from continuing a strip of real
        /// picture the same shape as the new one. Heal's scale, so the same
        /// number means the same thing in both features.
        public let error: Double
        public var isTrusted: Bool { error < Heal.trusted }
    }

    /// Grows `image` so it covers `box` as well, and draws whatever that adds.
    ///
    /// `box` is in the image's own pixel space, y down, and may sit partly or
    /// wholly outside it; negative origins mean growing up or left. Returns nil
    /// when there is nothing to add.
    public static func grow(_ image: CGImage, toCover box: CGRect) -> Result? {
        let current = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let union = current.union(box.integral).integral
        guard union != current, union.width > 0, union.height > 0 else { return nil }

        // A runaway box would ask for a canvas nothing can hold. Four times in
        // each direction is more than any real extension, and it stops a stray
        // drag allocating a gigabyte.
        guard union.width <= current.width * 4, union.height <= current.height * 4 else { return nil }

        let offset = CGPoint(x: current.minX - union.minX, y: current.minY - union.minY)
        guard var pixels = Pixels(image, size: union.size, at: offset) else { return nil }

        let old = CGRect(origin: offset, size: current.size)
        // Sides first, then top and bottom across the full width, so the corners
        // have filled pixels beside them to carry rather than blank canvas.
        for strip in strips(around: old, in: CGRect(origin: .zero, size: union.size)) {
            pixels.carryEdge(into: strip, from: old)
        }
        guard let out = pixels.image() else { return nil }
        return Result(image: out, offset: offset, error: grade(image, box: box))
    }

    /// How well this picture can be continued, measured on pixels we have.
    ///
    /// Take a band of the real picture as thick as the one being invented, just
    /// inside the edge it grows from, carry the edge next to it across, and
    /// compare with what is really there. If continuing the last forty rows
    /// reproduces them, the forty after them are worth trusting.
    static func grade(_ image: CGImage, box: CGRect) -> Double {
        let current = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let truth = Pixels(image, size: current.size, at: .zero) else { return .infinity }

        let down = max(0, box.maxY - current.maxY), up = max(0, current.minY - box.minY)
        let right = max(0, box.maxX - current.maxX), left = max(0, current.minX - box.minX)
        let vertical = max(down, up), horizontal = max(right, left)

        var band = CGRect.zero
        var source = CGRect.zero
        if vertical >= horizontal {
            let t = min(vertical, (current.height / 2).rounded(.down))
            guard t >= 2 else { return .infinity }
            if down >= up {
                band = CGRect(x: 0, y: current.maxY - t, width: current.width, height: t)
                source = CGRect(x: 0, y: 0, width: current.width, height: current.maxY - t)
            } else {
                band = CGRect(x: 0, y: 0, width: current.width, height: t)
                source = CGRect(x: 0, y: t, width: current.width, height: current.height - t)
            }
        } else {
            let t = min(horizontal, (current.width / 2).rounded(.down))
            guard t >= 2 else { return .infinity }
            if right >= left {
                band = CGRect(x: current.maxX - t, y: 0, width: t, height: current.height)
                source = CGRect(x: 0, y: 0, width: current.maxX - t, height: current.height)
            } else {
                band = CGRect(x: 0, y: 0, width: t, height: current.height)
                source = CGRect(x: t, y: 0, width: current.width - t, height: current.height)
            }
        }

        var attempt = truth
        attempt.carryEdge(into: band, from: source)
        return attempt.disagreement(with: truth, over: band)
    }

    /// The strips of `frame` that `old` does not cover.
    static func strips(around old: CGRect, in frame: CGRect) -> [CGRect] {
        var out: [CGRect] = []
        if old.minX > frame.minX {
            out.append(CGRect(x: frame.minX, y: old.minY, width: old.minX - frame.minX, height: old.height))
        }
        if old.maxX < frame.maxX {
            out.append(CGRect(x: old.maxX, y: old.minY, width: frame.maxX - old.maxX, height: old.height))
        }
        if old.minY > frame.minY {
            out.append(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: old.minY - frame.minY))
        }
        if old.maxY < frame.maxY {
            out.append(CGRect(x: frame.minX, y: old.maxY, width: frame.width, height: frame.maxY - old.maxY))
        }
        return out.filter { $0.width >= 1 && $0.height >= 1 }
    }

    /// A mutable RGBA buffer, y down from the top, premultiplied like every
    /// other bitmap in the app.
    struct Pixels {
        var bytes: [UInt8]
        let w: Int
        let h: Int

        init?(_ image: CGImage, size: CGSize, at offset: CGPoint) {
            w = Int(size.width); h = Int(size.height)
            guard w > 0, h > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            let width = w, height = h
            let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                // The caller thinks y-down; a bitmap context draws y-up. Convert
                // the offset rather than flipping the transform — flipping the
                // CTM mirrors the artwork as well as moving it, which came out
                // as a picture standing on its head.
                ctx.draw(image, in: CGRect(x: offset.x,
                                           y: CGFloat(height) - offset.y - CGFloat(image.height),
                                           width: CGFloat(image.width), height: CGFloat(image.height)))
                return true
            }
            guard drawn else { return nil }
            bytes = buffer
        }

        subscript(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            get {
                let i = (y * w + x) * 4
                return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
            }
            set {
                let i = (y * w + x) * 4
                bytes[i] = newValue.0; bytes[i + 1] = newValue.1
                bytes[i + 2] = newValue.2; bytes[i + 3] = newValue.3
            }
        }

        /// Fills `strip` by carrying the edge of `source` across it, following
        /// whatever direction the artwork was already travelling.
        ///
        /// Straight replication was the first version and it is wrong wherever
        /// anything is on a slant: Ship's hoodie leaves the bottom of the frame
        /// heading out to the left, and carrying it straight down turned it into
        /// a vertical column. Flat artwork along an edge is a run of colours, so
        /// reading the runs on two rows a few apart gives every boundary a
        /// direction, and the boundaries can be carried on rather than the
        /// pixels.
        ///
        /// Falls back to straight replication when the two rows do not agree
        /// about what is on them — that means something starts or ends inside
        /// the gap, and a velocity measured across it would be invented.
        mutating func carryEdge(into strip: CGRect, from source: CGRect) {
            if carrySlant(into: strip, from: source) { return }
            carryStraight(into: strip, from: source)
        }

        /// How far inside the picture to read the edge from.
        ///
        /// Never the last row. A cut-out has been trimmed to its content, so
        /// its final row is the anti-aliased boundary — half the colour and
        /// half the transparency behind it. Carrying that outward produced a
        /// pale, washed-out band that looked like a colour-space bug and was
        /// really a one-pixel-too-far bug.
        static let inset = 3

        /// Whether two colours are the same thing as far as this is concerned.
        ///
        /// Exact equality is useless on real artwork: every edge is
        /// anti-aliased, so a strict test finds a boundary at nearly every
        /// pixel and matches none of them to the row above. A flat style has
        /// few colours and they are far apart, so a generous tolerance
        /// separates them cleanly and ignores the ramp between.
        static func alike(_ a: (UInt8, UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
            abs(Int(a.0) - Int(b.0)) <= 28 && abs(Int(a.1) - Int(b.1)) <= 28 &&
            abs(Int(a.2) - Int(b.2)) <= 28 && abs(Int(a.3) - Int(b.3)) <= 28
        }

        /// Where one colour stops and the next begins, and which two they are.
        struct Edge {
            var at: Int
            var before: (UInt8, UInt8, UInt8, UInt8)
            var after: (UInt8, UInt8, UInt8, UInt8)
        }

        func edges(row y: Int, from a: Int, to b: Int) -> [Edge] {
            var out: [Edge] = []
            guard b - a > 1 else { return out }
            var last = self[a, y]
            for x in (a + 1)..<b where !Pixels.alike(self[x, y], last) {
                out.append(Edge(at: x, before: last, after: self[x, y]))
                last = self[x, y]
            }
            return out
        }

        func edges(column x: Int, from a: Int, to b: Int) -> [Edge] {
            var out: [Edge] = []
            guard b - a > 1 else { return out }
            var last = self[x, a]
            for y in (a + 1)..<b where !Pixels.alike(self[x, y], last) {
                out.append(Edge(at: y, before: last, after: self[x, y]))
                last = self[x, y]
            }
            return out
        }

        /// Carries the edge on along the direction each colour boundary was
        /// already moving. Returns false when there is nothing to follow.
        mutating func carrySlant(into strip: CGRect, from source: CGRect) -> Bool {
            let x0 = max(0, Int(strip.minX)), x1 = min(w, Int(strip.maxX))
            let y0 = max(0, Int(strip.minY)), y1 = min(h, Int(strip.maxY))
            guard x1 > x0, y1 > y0 else { return false }

            // How far back to look for the direction. Too short and a stepped
            // outline reads as vertical; too long and a curve reads as the
            // chord across it.
            let look = 12

            if strip.width >= strip.height {
                let down = strip.minY >= source.maxY
                let edge = down ? Int(source.maxY) - 1 - Pixels.inset : Int(source.minY) + Pixels.inset
                let back = down ? edge - look : edge + look
                guard back >= Int(source.minY), back < Int(source.maxY) else { return false }
                let lo = max(x0, Int(source.minX)), hi = min(x1, Int(source.maxX))
                let here = edges(row: edge, from: lo, to: hi)
                guard !here.isEmpty else { return false }
                let moving = pairUp(here, with: edges(row: back, from: lo, to: hi), over: look)
                let first = self[lo, edge]
                for y in y0..<y1 {
                    paint(row: y, first: first, edges: moving, depth: down ? y - edge : edge - y,
                          from: x0, to: x1)
                }
                return true
            }

            let right = strip.minX >= source.maxX
            let edge = right ? Int(source.maxX) - 1 - Pixels.inset : Int(source.minX) + Pixels.inset
            let back = right ? edge - look : edge + look
            guard back >= Int(source.minX), back < Int(source.maxX) else { return false }
            let lo = max(y0, Int(source.minY)), hi = min(y1, Int(source.maxY))
            let here = edges(column: edge, from: lo, to: hi)
            guard !here.isEmpty else { return false }
            let moving = pairUp(here, with: edges(column: back, from: lo, to: hi), over: look)
            let first = self[edge, lo]
            for x in x0..<x1 {
                paint(column: x, first: first, edges: moving, depth: right ? x - edge : edge - x,
                      from: y0, to: y1)
            }
            return true
        }

        /// Gives every boundary a speed by finding the same boundary a few rows
        /// back — the same two colours, nearest in position.
        ///
        /// Matched one at a time rather than as a sequence. Requiring the whole
        /// line to agree was the first attempt, and on any real drawing it never
        /// does: something always starts or ends within twelve rows, and one
        /// mismatch anywhere threw away the direction of every boundary on the
        /// line. A boundary with no partner simply doesn't move.
        func pairUp(_ here: [Edge], with back: [Edge], over look: Int) -> [(Edge, Double)] {
            here.map { edge in
                let partner = back
                    .filter { Pixels.alike($0.before, edge.before) && Pixels.alike($0.after, edge.after) }
                    .min { abs($0.at - edge.at) < abs($1.at - edge.at) }
                guard let partner, abs(partner.at - edge.at) <= look * 2 else { return (edge, 0.0) }
                // Clamped: anything faster than a pixel per row is nearly always
                // two unrelated edges paired up, and following it fans the
                // picture out into stripes.
                let v = Double(edge.at - partner.at) / Double(look)
                return (edge, max(-1.0, min(1.0, v)))
            }
        }

        mutating func paint(row y: Int, first: (UInt8, UInt8, UInt8, UInt8),
                            edges: [(Edge, Double)], depth: Int, from x0: Int, to x1: Int) {
            for x in x0..<x1 {
                self[x, y] = colour(at: x, first: first, edges: edges, depth: depth)
            }
        }

        mutating func paint(column x: Int, first: (UInt8, UInt8, UInt8, UInt8),
                            edges: [(Edge, Double)], depth: Int, from y0: Int, to y1: Int) {
            for y in y0..<y1 {
                self[x, y] = colour(at: y, first: first, edges: edges, depth: depth)
            }
        }

        /// Which colour lands at `pos` once every boundary has moved on.
        func colour(at pos: Int, first: (UInt8, UInt8, UInt8, UInt8),
                    edges: [(Edge, Double)], depth: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            var out = first
            for (edge, speed) in edges {
                if Double(pos) >= Double(edge.at) + speed * Double(depth) { out = edge.after } else { break }
            }
            return out
        }

        /// Fills `strip` by carrying the nearest row or column of `source`
        /// straight across it.
        mutating func carryStraight(into strip: CGRect, from source: CGRect) {
            let x0 = max(0, Int(strip.minX)), x1 = min(w, Int(strip.maxX))
            let y0 = max(0, Int(strip.minY)), y1 = min(h, Int(strip.maxY))
            guard x1 > x0, y1 > y0, source.width >= 1, source.height >= 1 else { return }

            for y in y0..<y1 {
                for x in x0..<x1 {
                    // The nearest real pixel is this one clamped back into the
                    // picture, which is what "carry the edge" means and handles
                    // the corners without a special case.
                    // Insets on every side for the same reason the slanted
                    // path does: the outermost row of a trimmed cut-out is a
                    // blend, not a colour.
                    let lo = Pixels.inset
                    let sx = min(max(x, Int(source.minX) + lo), Int(source.maxX) - 1 - lo)
                    let sy = min(max(y, Int(source.minY) + lo), Int(source.maxY) - 1 - lo)
                    guard sx >= 0, sy >= 0, sx < w, sy < h else { continue }
                    self[x, y] = self[sx, sy]
                }
            }
        }

        /// Average worst-channel difference against `other` over `region`.
        func disagreement(with other: Pixels, over region: CGRect) -> Double {
            var total = 0.0
            var count = 0
            for y in max(0, Int(region.minY))..<min(h, Int(region.maxY)) {
                for x in max(0, Int(region.minX))..<min(w, Int(region.maxX)) {
                    let a = self[x, y], b = other[x, y]
                    let d = max(max(abs(Int(a.0) - Int(b.0)), abs(Int(a.1) - Int(b.1))),
                                max(abs(Int(a.2) - Int(b.2)), abs(Int(a.3) - Int(b.3))))
                    total += Double(d)
                    count += 1
                }
            }
            return count == 0 ? .infinity : total / Double(count)
        }

        func image() -> CGImage? {
            var copy = bytes
            let width = w, height = h
            return copy.withUnsafeMutableBytes { raw -> CGImage? in
                guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return nil }
                return ctx.makeImage()
            }
        }
    }
}
