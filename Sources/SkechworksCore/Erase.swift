import CoreGraphics
import Foundation

// Erasing a bitmap, without editing the bitmap.
//
// Photoshop erases pixels. That's the wrong trade for a design tool where the same
// photo appears on four coins: a stroke is a decision, and decisions should stay
// changeable. Strokes are stored on the layer and applied when it draws, so an erase
// can be undone, adjusted, or thrown away months later, and the original bytes are
// never touched — which also means the file keeps ONE copy of the photo however many
// times it's been erased differently.

public struct EraseStroke: Sendable, Equatable {
    /// Where the brush went, in the layer's own coordinates.
    public var points: [CGPoint]
    /// Brush radius in layer units.
    public var radius: CGFloat
    /// 0 is a hard edge, 1 fades the whole radius out. Anything in between fades the
    /// outer part and leaves a solid core.
    public var softness: CGFloat
    /// A rectangular patch instead of a brush path — the marquee erase. When set,
    /// points and radius are ignored.
    public var rect: CGRect?
    /// A closed outline instead of a brush path or a rectangle — what the wand
    /// picks out, and what a shape eraser would draw. In the layer's own
    /// coordinates, like everything else here. When set, the others are ignored.
    ///
    /// An outline rather than a mask because a stroke has to survive being
    /// saved, reopened and undone, and a handful of points does that where a
    /// second picture kept beside the first one forever does not.
    public var polygon: [CGPoint]?
    /// Rings inside `polygon` that the erase leaves alone, filled even-odd. The
    /// wand's answer to a background with something in the middle of it.
    public var holes: [[CGPoint]] = []

    public init(points: [CGPoint], radius: CGFloat, softness: CGFloat = 0.5) {
        self.points = points
        self.radius = max(0.5, radius)
        self.softness = min(1, max(0, softness))
    }

    /// A marquee erase: one hard-edged rectangle.
    public init(rect: CGRect) {
        self.points = []
        self.radius = 1
        self.softness = 0
        self.rect = rect
    }

    /// An erase shaped like whatever was selected.
    public init(polygon: [CGPoint], holes: [[CGPoint]] = []) {
        self.points = []
        self.radius = 1
        self.softness = 0
        self.polygon = polygon
        self.holes = holes.filter { $0.count >= 3 }
    }

    /// The same stroke, shifted.
    ///
    /// Every kind of stroke has to move, and this exists so that adding a new
    /// kind cannot quietly leave one behind. It has twice: trimming a layer
    /// down to what is left after an erase moves the frame out from under the
    /// strokes, and any stroke that stays put then rubs its hole somewhere
    /// else. The mask is built at the new frame's size, so the next erase
    /// measures a different picture, trims to a different box, and the frame
    /// walks away from the artwork a step at a time — once as far as 3,360
    /// pixels out of a picture 1,120 wide.
    public func moved(dx: CGFloat, dy: CGFloat) -> EraseStroke {
        var out = self
        out.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        out.rect = rect?.offsetBy(dx: dx, dy: dy)
        out.polygon = polygon?.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        out.holes = holes.map { $0.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } }
        return out
    }

    /// How far the stroke reaches, for invalidation and for sizing the mask.
    public var bounds: CGRect {
        if let rect { return rect }
        if let polygon, let first = polygon.first {
            return polygon.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
        }
        guard var box = points.first.map({ CGRect(origin: $0, size: .zero) }) else { return .null }
        for p in points { box = box.union(CGRect(origin: p, size: .zero)) }
        return box.insetBy(dx: -radius, dy: -radius)
    }
}

public enum EraseMask {

    /// Builds the alpha mask for a layer's erase strokes.
    ///
    /// White keeps, black hides — CGContext.clip(to:mask:) reads the mask's value as
    /// the alpha to paint with, so the default has to be white or the whole image
    /// disappears.
    ///
    /// `scale` is pixels per layer unit: a soft edge has to be built at the size it
    /// will be seen at, or zooming in shows the mask's own resolution rather than the
    /// blur it stands for.
    public static func image(strokes: [EraseStroke], size: CGSize, scale: CGFloat = 2) -> CGImage? {
        guard !strokes.isEmpty, size.width > 0, size.height > 0 else { return nil }
        // The canvas asks for this on every frame a picture with erasing on it
        // is in view. The strokes only change while the brush is down.
        let k = key(strokes: strokes, size: size, scale: scale)
        if let hit = cache.object(forKey: k) { return hit }

        // While the brush is down, every frame asks for the same strokes with a
        // few more points on the last one. Rebuilding from nothing each time
        // redrew every dab of the stroke so far, so a long drag got slower the
        // longer it went. The last mask built is kept open instead, and only the
        // new stretch of the line is drawn onto it.
        liveLock.lock()
        defer { liveLock.unlock() }
        if let l = live, l.key == k { return l.image }
        if let l = live, l.size == size, l.scale == scale, l.extend(to: strokes) {
            l.key = k
            l.image = l.ctx.makeImage()
            return l.image
        }

        // Starting over on something else. Whatever the old one ended on is
        // usually the stroke that was just committed, so it goes in the cache.
        if let l = live, let done = l.image {
            cache.setObject(done, forKey: l.key, cost: done.width * done.height)
        }
        guard let ctx = context(size: size, scale: scale) else { return nil }
        for stroke in strokes { stamp(stroke, in: ctx) }
        let built = ctx.makeImage()
        live = Live(ctx: ctx, size: size, scale: scale, strokes: strokes, key: k, image: built)
        if let built { cache.setObject(built, forKey: k, cost: built.width * built.height) }
        return built
    }

    /// The mask being drawn into while a brush stroke is in progress.
    private final class Live {
        let ctx: CGContext
        let size: CGSize
        let scale: CGFloat
        var strokes: [EraseStroke]
        var key: NSString
        var image: CGImage?

        init(ctx: CGContext, size: CGSize, scale: CGFloat, strokes: [EraseStroke], key: NSString, image: CGImage?) {
            self.ctx = ctx; self.size = size; self.scale = scale
            self.strokes = strokes; self.key = key; self.image = image
        }

        /// Draws what `strokes` has that this mask doesn't yet, when that is
        /// only more of the last brush stroke or new strokes on the end.
        /// False when anything already drawn changed, and then it draws nothing.
        func extend(to next: [EraseStroke]) -> Bool {
            let n = strokes.count
            guard n > 0, next.count >= n, Array(next[0..<(n - 1)]) == Array(strokes[0..<(n - 1)]) else { return false }
            let was = strokes[n - 1], now = next[n - 1]
            if was != now {
                guard was.rect == nil, was.polygon == nil, now.rect == nil, now.polygon == nil,
                      was.radius == now.radius, was.softness == now.softness,
                      now.points.count > was.points.count,
                      Array(now.points[0..<was.points.count]) == was.points else { return false }
                EraseMask.stampBrush(now, in: ctx, from: was.points.count)
            }
            for stroke in next[n...] { EraseMask.stamp(stroke, in: ctx) }
            strokes = next
            return true
        }
    }

    nonisolated(unsafe) private static var live: Live?
    private static let liveLock = NSLock()

    // NSCache is documented thread-safe; the checker can't see that.
    nonisolated(unsafe) private static let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.totalCostLimit = 128 << 20
        return c
    }()

    private static func key(strokes: [EraseStroke], size: CGSize, scale: CGFloat) -> NSString {
        var h = Hasher()
        h.combine(size.width); h.combine(size.height); h.combine(scale)
        h.combine(strokes.count)
        for s in strokes {
            h.combine(s.radius); h.combine(s.softness)
            h.combine(s.points.count)
            for p in s.points { h.combine(p.x); h.combine(p.y) }
            if let r = s.rect { h.combine(r.minX); h.combine(r.minY); h.combine(r.width); h.combine(r.height) }
            if let poly = s.polygon { for p in poly { h.combine(p.x); h.combine(p.y) } }
            for hole in s.holes { h.combine(hole.count); for p in hole { h.combine(p.x); h.combine(p.y) } }
        }
        return "\(h.finalize())" as NSString
    }

    static func context(size: CGSize, scale: CGFloat) -> CGContext? {
        let w = max(1, Int((size.width * scale).rounded()))
        let h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }

        ctx.setFillColor(gray: 1, alpha: 1)      // keep everything by default
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        // Layer coordinates are y-down; the mask is drawn y-up.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    /// Draws one stroke as a run of overlapping soft stamps.
    ///
    /// Stamping rather than stroking a path: a soft edge is a gradient per dab, and a
    /// stroked line can only have one colour. Spacing is a quarter of the radius,
    /// which is close enough that the dabs read as a line rather than a string of
    /// beads, without costing a stamp per pixel.
    static func stamp(_ stroke: EraseStroke, in ctx: CGContext) {
        // A marquee patch is one hard-edged rectangle, not a run of dabs.
        if let r = stroke.rect {
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(r)
            return
        }
        // A selected area is its own outline, filled, minus any holes in it.
        if let poly = stroke.polygon, poly.count >= 3 {
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.beginPath()
            ctx.addLines(between: poly)
            ctx.closePath()
            for hole in stroke.holes where hole.count >= 3 {
                ctx.addLines(between: hole)
                ctx.closePath()
            }
            ctx.fillPath(using: .evenOdd)
            return
        }
        stampBrush(stroke, in: ctx, from: 0)
    }

    /// Stamps a brush stroke's dabs from point `start` on. Zero draws the whole
    /// stroke. A later start draws exactly the dabs a full draw would add for
    /// the points past it, so a stroke built up a few points a frame comes out
    /// the same as one drawn in one go.
    static func stampBrush(_ stroke: EraseStroke, in ctx: CGContext, from start: Int) {
        let spacing = max(0.5, stroke.radius / 4)
        var dabs: [CGPoint] = []
        if stroke.points.count == 1 {
            dabs = stroke.points
        } else {
            for i in max(1, start)..<stroke.points.count {
                let a = stroke.points[i - 1], b = stroke.points[i]
                let d = hypot(b.x - a.x, b.y - a.y)
                let steps = max(1, Int((d / spacing).rounded(.up)))
                // A lone first point was already stamped on its own; its first
                // segment must not stamp it again or a soft brush goes darker there.
                let first = (start == 1 && i == 1) ? 1 : 0
                for s in first...steps {
                    let t = CGFloat(s) / CGFloat(steps)
                    dabs.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                }
            }
        }

        if stroke.softness <= 0.001 {
            ctx.setFillColor(gray: 0, alpha: 1)
            for p in dabs {
                ctx.fillEllipse(in: CGRect(x: p.x - stroke.radius, y: p.y - stroke.radius,
                                           width: stroke.radius * 2, height: stroke.radius * 2))
            }
            return
        }
        let solid = 1 - stroke.softness      // the fraction of the radius left hard
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                        colors: [CGColor(gray: 0, alpha: 1),
                                                 CGColor(gray: 0, alpha: 0)] as CFArray,
                                        locations: [solid, 1]) else { return }
        ctx.saveGState()
        ctx.setBlendMode(.multiply)      // overlapping dabs deepen rather than reset
        // No .drawsAfterEndLocation: past the radius the gradient is clear, and
        // extending clear paint to infinity multiplied every pixel of the mask
        // once per dab. A long soft stroke took 23 seconds to draw that way.
        for p in dabs {
            ctx.drawRadialGradient(gradient, startCenter: p, startRadius: 0,
                                   endCenter: p, endRadius: stroke.radius, options: [])
        }
        ctx.restoreGState()
    }
}
