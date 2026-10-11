import CoreGraphics
import Foundation

// Painting on a bitmap, without editing the bitmap.
//
// The brush is the eraser with a color in it. A stroke is stored on the layer
// and drawn when the layer draws, for the reasons Erase.swift gives: it can be
// undone or thrown away months later, and the file keeps one copy of the photo
// however much has been drawn on it.

public enum PaintOverlay {

    /// Everything the brush has put on a layer, as a clear picture to draw over
    /// it. Nil when nothing has been painted.
    ///
    /// The strokes are walked in the order they were made. Paint goes down in
    /// its color; an erase that came after it takes it back out. Erases from
    /// before the first paint stroke have nothing here to take out, and the
    /// mask deals with the picture underneath.
    ///
    /// `scale` is pixels per layer unit, the same as the mask's.
    public static func image(strokes all: [EraseStroke], size: CGSize, scale: CGFloat = 2) -> CGImage? {
        guard let first = all.firstIndex(where: { $0.paint != nil }),
              size.width > 0, size.height > 0 else { return nil }
        let strokes = Array(all[first...])
        let k = key(strokes, size: size, scale: scale)
        if let hit = cache.object(forKey: k) { return hit }

        lock.lock()
        defer { lock.unlock() }
        if let l = live, l.key == k { return l.image }

        // While the brush is down every frame asks for the same strokes with a
        // few more points on the last one. What lies under that stroke is kept,
        // and only the new stretch of the line is stamped.
        let last = strokes[strokes.count - 1]
        let before = Array(strokes.dropLast())
        let underKey = key(before, size: size, scale: scale)
        if let l = live, l.underKey == underKey, l.size == size, l.scale == scale, l.extend(to: last),
           let cover = l.cover.makeImage(), let out = compose(under: l.under, [(last, cover)], size: size, scale: scale) {
            l.key = k
            l.image = out
            return out
        }

        // Starting over on something else. Whatever the old one ended on is
        // usually the stroke that was just committed, so it goes in the cache,
        // and is very often what lies under the stroke now starting.
        if let l = live, let done = l.image {
            cache.setObject(done, forKey: l.key, cost: done.width * done.height * 4)
        }
        var under: CGImage?
        if !before.isEmpty {
            under = cache.object(forKey: underKey)
            if under == nil {
                under = compose(under: nil, before.compactMap { s in coverage(s, size: size, scale: scale).map { (s, $0) } },
                                size: size, scale: scale)
                if let under { cache.setObject(under, forKey: underKey, cost: under.width * under.height * 4) }
            }
        }
        guard let ctx = EraseMask.context(size: size, scale: scale, paper: 0) else { return nil }
        EraseMask.stamp(last, in: ctx, ink: 1)
        guard let cover = ctx.makeImage(),
              let out = compose(under: under, [(last, cover)], size: size, scale: scale) else { return nil }
        live = Live(cover: ctx, stroke: last, under: under, underKey: underKey, size: size, scale: scale, key: k, image: out)
        return out
    }

    /// Where one stroke lands: white where it is, black where it is not.
    private static func coverage(_ stroke: EraseStroke, size: CGSize, scale: CGFloat) -> CGImage? {
        guard let ctx = EraseMask.context(size: size, scale: scale, paper: 0) else { return nil }
        EraseMask.stamp(stroke, in: ctx, ink: 1)
        return ctx.makeImage()
    }

    /// Lays strokes over `under`, each through its own coverage.
    ///
    /// A stroke is stamped as coverage first and colored once, so a see-through
    /// color is the same strength all along the line. Colored a dab at a time
    /// it would darken wherever two dabs overlap, which is everywhere.
    private static func compose(under: CGImage?, _ strokes: [(EraseStroke, CGImage)],
                                size: CGSize, scale: CGFloat) -> CGImage? {
        let w = max(1, Int((size.width * scale).rounded()))
        let h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        if let under { ctx.draw(under, in: full) }
        for (stroke, cover) in strokes {
            ctx.saveGState()
            ctx.clip(to: full, mask: cover)
            if let color = stroke.paint {
                ctx.setFillColor(color.cg)
            } else {
                ctx.setBlendMode(.destinationOut)
                ctx.setFillColor(gray: 0, alpha: 1)
            }
            ctx.fill(full)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// The stroke being drawn, and what it is being drawn over.
    private final class Live {
        let cover: CGContext
        var stroke: EraseStroke
        let under: CGImage?
        let underKey: NSString
        let size: CGSize
        let scale: CGFloat
        var key: NSString
        var image: CGImage?

        init(cover: CGContext, stroke: EraseStroke, under: CGImage?, underKey: NSString,
             size: CGSize, scale: CGFloat, key: NSString, image: CGImage?) {
            self.cover = cover; self.stroke = stroke; self.under = under; self.underKey = underKey
            self.size = size; self.scale = scale; self.key = key; self.image = image
        }

        /// Stamps what `next` has that the coverage doesn't yet, when that is
        /// only more of the same brush stroke. False when it is anything else,
        /// and then it stamps nothing.
        func extend(to next: EraseStroke) -> Bool {
            let was = stroke
            guard was.rect == nil, was.polygon == nil, next.rect == nil, next.polygon == nil,
                  was.radius == next.radius, was.softness == next.softness, was.paint == next.paint,
                  next.points.count > was.points.count,
                  Array(next.points[0..<was.points.count]) == was.points else { return false }
            EraseMask.stampBrush(next, in: cover, from: was.points.count, ink: 1)
            stroke = next
            return true
        }
    }

    nonisolated(unsafe) private static var live: Live?
    private static let lock = NSLock()

    // NSCache is documented thread-safe; the checker can't see that.
    nonisolated(unsafe) private static let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.totalCostLimit = 256 << 20
        return c
    }()

    private static func key(_ strokes: [EraseStroke], size: CGSize, scale: CGFloat) -> NSString {
        var h = Hasher()
        h.combine(size.width); h.combine(size.height); h.combine(scale)
        h.combine(strokes.count)
        for s in strokes {
            h.combine(s.radius); h.combine(s.softness)
            if let c = s.paint { h.combine(c.r); h.combine(c.g); h.combine(c.b); h.combine(c.a) } else { h.combine(-1) }
            h.combine(s.points.count)
            for p in s.points { h.combine(p.x); h.combine(p.y) }
            if let r = s.rect { h.combine(r.minX); h.combine(r.minY); h.combine(r.width); h.combine(r.height) }
            if let poly = s.polygon { for p in poly { h.combine(p.x); h.combine(p.y) } }
            for hole in s.holes { h.combine(hole.count); for p in hole { h.combine(p.x); h.combine(p.y) } }
        }
        return "paint\(h.finalize())" as NSString
    }
}
