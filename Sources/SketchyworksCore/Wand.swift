import CoreGraphics
import Foundation

/// Picking out an area of one colour by clicking in it.
///
/// Flat artwork is the case this is for. A hoodie is one green, a muzzle is one
/// cream, and the thing you want to select is "that patch" — which is a flood
/// fill from where you clicked, stopped by the black outline around it.
///
/// The answer comes back as an OUTLINE rather than as a mask, because erasing
/// in this app is a stored decision and decisions have to survive being saved,
/// reopened and undone. A polygon is a handful of points on the layer; a mask
/// is a second picture to keep beside the first one forever.
public enum Wand {

    /// How far a colour can be from the one clicked and still count as the same
    /// thing. On the app's own artwork the gaps between palette colours are
    /// enormous, so this only has to be bigger than anti-aliasing.
    public static let defaultTolerance = 32

    /// The outline of the area around `point`, in image pixels, y down.
    ///
    /// Nil when the click lands somewhere with nothing to select — off the
    /// picture, or on a region so small it is a stray pixel.
    public static func outline(in image: CGImage, at point: CGPoint,
                               tolerance: Int = defaultTolerance) -> [CGPoint]? {
        guard let mask = region(in: image, at: point, tolerance: tolerance) else { return nil }
        guard let traced = trace(mask.bits, w: mask.w, h: mask.h) else { return nil }
        return simplify(traced, epsilon: 1.2)
    }

    /// The filled area itself, as a bitmap of flags.
    static func region(in image: CGImage, at point: CGPoint, tolerance: Int)
        -> (bits: [Bool], w: Int, h: Int)? {
        let w = image.width, h = image.height
        let sx = Int(point.x.rounded(.down)), sy = Int(point.y.rounded(.down))
        guard w > 0, h > 0, sx >= 0, sy >= 0, sx < w, sy < h else { return nil }

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        func at(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
        }
        let seed = at(sx, sy)
        func alike(_ c: (Int, Int, Int, Int)) -> Bool {
            // Transparency is its own thing: a see-through pixel and an opaque
            // one are never the same area however close their colours look,
            // because premultiplied channels of a clear pixel are all zero and
            // would match black.
            if (seed.3 < 8) != (c.3 < 8) { return false }
            return abs(c.0 - seed.0) <= tolerance && abs(c.1 - seed.1) <= tolerance
                && abs(c.2 - seed.2) <= tolerance && abs(c.3 - seed.3) <= tolerance
        }

        // Scanline flood fill: rows at a time rather than a stack entry per
        // pixel, because a hoodie is a hundred thousand pixels and a per-pixel
        // stack is a hundred thousand allocations deep.
        var bits = [Bool](repeating: false, count: w * h)
        var stack = [(sx, sx, sy, 0)]
        var count = 0
        while let (x1s, x2s, y, _) = stack.popLast() {
            guard y >= 0, y < h else { continue }
            var x1 = x1s
            while x1 > 0 && !bits[y * w + x1 - 1] && alike(at(x1 - 1, y)) { x1 -= 1 }
            var x2 = x2s
            while x2 < w - 1 && !bits[y * w + x2 + 1] && alike(at(x2 + 1, y)) { x2 += 1 }
            for x in x1...x2 where !bits[y * w + x] {
                bits[y * w + x] = true
                count += 1
            }
            for next in [y - 1, y + 1] where next >= 0 && next < h {
                var x = x1
                while x <= x2 {
                    if !bits[next * w + x] && alike(at(x, next)) {
                        let start = x
                        while x <= x2 && !bits[next * w + x] && alike(at(x, next)) { x += 1 }
                        stack.append((start, x - 1, next, 0))
                    } else {
                        x += 1
                    }
                }
            }
        }
        guard count > 4 else { return nil }
        return (bits, w, h)
    }

    /// Walks the outside of a filled area and returns it as a ring of points.
    ///
    /// Square-tracing: step along the boundary turning left on a filled cell and
    /// right on an empty one, until it comes back to where it started facing the
    /// way it started. Only the OUTER ring — a selected area with a hole in it
    /// comes back solid, which for a patch of flat colour is nearly always what
    /// was meant anyway.
    static func trace(_ bits: [Bool], w: Int, h: Int) -> [CGPoint]? {
        func filled(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < w && y < h && bits[y * w + x]
        }
        guard let start = (0..<(w * h)).first(where: { bits[$0] }) else { return nil }
        let sx = start % w, sy = start / w

        // Directions, clockwise from east. The walk keeps the filled area on its
        // right by turning left when it can and right when it must.
        let dx = [1, 0, -1, 0], dy = [0, 1, 0, -1]
        var x = sx, y = sy, dir = 0
        var out: [CGPoint] = []
        let limit = (w + h) * 8

        repeat {
            out.append(CGPoint(x: x, y: y))
            var turned = false
            for turn in [3, 0, 1, 2] {          // left, straight, right, back
                let d = (dir + turn) % 4
                let nx = x + dx[d], ny = y + dy[d]
                if filled(nx, ny) {
                    x = nx; y = ny; dir = d; turned = true
                    break
                }
            }
            if !turned { break }
        } while !(x == sx && y == sy) && out.count < limit

        return out.count >= 4 ? out : nil
    }

    /// Drops the points that were only ever describing a straight line.
    ///
    /// A traced boundary has a point per pixel, and a hoodie's outline is
    /// thousands of them. Flat artwork is mostly long straight runs, so this
    /// throws away the overwhelming majority without moving the shape more than
    /// a pixel.
    static func simplify(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var work = [(0, points.count - 1)]
        while let (a, b) = work.popLast() {
            guard b > a + 1 else { continue }
            var worst = 0.0, index = a
            for i in (a + 1)..<b {
                let d = distance(points[i], from: points[a], to: points[b])
                if d > worst { worst = d; index = i }
            }
            if worst > epsilon {
                keep[index] = true
                work.append((a, index))
                work.append((index, b))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    static func distance(_ p: CGPoint, from a: CGPoint, to b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len
    }
}
