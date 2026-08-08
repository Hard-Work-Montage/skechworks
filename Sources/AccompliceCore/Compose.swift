import CoreGraphics
import Foundation

// Resolves a layer tree into concrete outlines.
//
// Both the raster renderer and the SVG writer go through here, so they can never
// disagree about geometry — which matters when the SVG is what gets engraved.

public enum Compose {

    /// Maps a layer's local space (0,0 … w,h) into its parent's coordinate space.
    public static func transform(_ l: Layer) -> CGAffineTransform {
        var t = CGAffineTransform(translationX: l.frame.minX, y: l.frame.minY)
        guard l.rotation != 0 || l.flipH || l.flipV else { return t }
        let cx = l.frame.width / 2, cy = l.frame.height / 2
        t = t.translatedBy(x: cx, y: cy)
        // Sketch reports rotation counter-clockwise; our canvas is y-down, so negate.
        if l.rotation != 0 { t = t.rotated(by: -l.rotation * .pi / 180) }
        if l.flipH { t = t.scaledBy(x: -1, y: 1) }
        if l.flipV { t = t.scaledBy(x: 1, y: -1) }
        return t.translatedBy(x: -cx, y: -cy)
    }

    /// Where a layer's frame has to sit once its path has been renormalised to
    /// start at the origin, so the shape doesn't budge on screen.
    ///
    /// Editing a path leaves its points wherever they were dragged to, which is
    /// rarely flush with the frame. The path gets shifted back to 0,0 and the
    /// frame is meant to absorb the difference. Adding the shift to the frame
    /// origin does that — but only for a layer that isn't flipped or rotated.
    ///
    /// A flip mirrors the path about the CENTRE of the frame, so changing the
    /// frame moves the mirror. Pull the leftmost point of a flipped shape to the
    /// right and the naive sum moves the frame left by exactly as much as the
    /// mirror moves the point right; the two cancel and the point lands back
    /// where it started. Which is what "I move them right and they go left"
    /// looks like from the outside.
    ///
    /// Solved rather than special-cased: the layer's own transform says where
    /// the path's corner sits now, the same transform at the origin says where
    /// the renormalised corner would sit, and the frame origin is the difference.
    /// Rotation comes out in the wash, since both transforms share a linear part
    /// and only their translations differ.
    public static func reframed(_ l: Layer, localBounds box: CGRect) -> CGRect {
        var atOrigin = l
        atOrigin.frame = CGRect(origin: .zero, size: box.size)
        let now = box.origin.applying(transform(l))
        let renormalised = CGPoint.zero.applying(transform(atOrigin))
        return CGRect(origin: CGPoint(x: now.x - renormalised.x, y: now.y - renormalised.y),
                      size: box.size)
    }

    /// The layer's outline in its OWN local space, with all boolean ops applied.
    /// Returns nil for anything that isn't a shape (text, bitmaps, plain groups).
    public static func resolvedPath(_ l: Layer) -> CGPath? {
        switch l.kind {
        case .path(let p, _):
            // The one place a corner radius turns into geometry. Everything downstream
            // — the renderer, the SVG writer, boolean ops, masks, hit-testing — reads
            // the shape through here, so none of them has to know the radius exists.
            // Not just the layer value: a single anchor can carry a radius where
            // the shape's own is zero.
            guard l.cornerRadius > 0 || l.cornerRadii.contains(where: { $0 > 0 }) else { return p }
            return Corners.round(p, radius: l.cornerRadius, style: l.cornerStyle,
                                 radii: l.cornerRadii)

        case .shapeGroup(let children, let winding):
            let acc = combine(children, winding: winding)
            // Bake the winding rule in, so parents can compose us with plain non-zero
            // and still get the ring holes right.
            if let a = acc, winding == .evenOdd { return a.normalized(using: .evenOdd) }
            return acc

        case .group(let children):
            // Sketch permits a plain group inside a shape group, and its contents still
            // take part in the parent's boolean composition. Miss this and whole
            // elements silently vanish from the artwork.
            return combine(children, winding: .nonZero)

        default:
            return nil
        }
    }

    private static func combine(_ children: [Layer], winding: WindingRule) -> CGPath? {
        let rule: CGPathFillRule = (winding == .evenOdd) ? .evenOdd : .winding
        var acc: CGPath?
        // A run of union'd children resolves in ONE planar pass, not one per child.
        // Normalize each operand (fixes its interior under the group rule), stack the
        // results — every interior point then has winding ≥ 1, so a single non-zero
        // normalize of the stack IS the union. Unions associate, so this equals the
        // pairwise fold — minus the n-1 full-document sweeps that made a vectorized
        // trace (hundreds of union'd glyph paths) unusable to recompose per frame.
        var pending: [CGPath] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let stack = CGMutablePath()
            for p in pending { stack.addPath(p.normalized(using: rule)) }
            pending = []
            let merged = stack.normalized(using: .winding)
            acc = acc.map { $0.union(merged, using: rule) } ?? merged
        }
        for c in children where c.isVisible {
            guard let raw = resolvedPath(c) else { continue }
            let p = raw.transformed(by: transform(c))
            guard acc != nil || !pending.isEmpty else { acc = p; continue }
            switch c.booleanOp {
            case .none:
                // No op: just another subpath. The winding rule decides what fills —
                // this is how Sketch stores a ring as two concentric circles.
                flush()
                let m = CGMutablePath()
                if let a = acc { m.addPath(a) }
                m.addPath(p)
                acc = m.copy()
            case .union:      pending.append(p)
            case .subtract:   flush(); acc = acc?.subtracting(p, using: rule)
            case .intersect:  flush(); acc = acc?.intersection(p, using: rule)
            case .difference: flush(); acc = acc?.symmetricDifference(p, using: rule)
            }
        }
        flush()
        return acc
    }

    /// Depth-first walk yielding every drawable together with its full canvas transform.
    /// Clipping masks are resolved here so callers don't each reimplement mask chains.
    ///
    /// `adjusting` names layers being moved or resized right now, with `live` the
    /// transform to apply to them. Previewing a drag by translating the drawing context
    /// instead moves each drawable's CLIP along with it — so dragging an image inside a
    /// mask appeared to take the mask along, then snapped back on release. Feeding the
    /// gesture through here keeps paint, masks and artboard edges consistent, because
    /// they are all derived from the same geometry.
    public static func flatten(_ layers: [Layer], base: CGAffineTransform = .identity,
                               adjusting: Set<String> = [], live: CGAffineTransform = .identity)
        -> [Drawable] {
        var out: [Drawable] = []
        var mask: CGPath?

        for l in layers where l.isVisible {
            // Applied at the layer being dragged; its descendants inherit it through
            // `base`, so it lands exactly once.
            var t = transform(l).concatenating(base)
            if adjusting.contains(l.id) { t = t.concatenating(live) }

            if l.breaksMaskChain { mask = nil }

            if l.hasClippingMask, let p = resolvedPath(l) {
                mask = p.transformed(by: t)
                continue   // the mask layer itself isn't painted
            }

            switch l.kind {
            case .group(let kids):
                var inner = flatten(kids, base: t, adjusting: adjusting, live: live)
                if l.isArtboard {
                    // The artboard's own rect: paint its background first, then clip
                    // everything inside it to the edge, the way Sketch does.
                    let rect = CGPath(rect: CGRect(origin: .zero, size: l.frame.size), transform: nil)
                        .transformed(by: t)
                    if let bg = l.backgroundColor {
                        var plate = Layer(kind: .path(CGPath(rect: CGRect(origin: .zero, size: l.frame.size), transform: nil), closed: true))
                        // The plate IS the artboard as far as anything downstream is
                        // concerned — same id, same isArtboard. A synthesized identity
                        // here meant canvas hit-testing saw a plain path named
                        // "Artboard" and treated a press on the board like a press on
                        // a shape, which ate the marquee.
                        plate.id = l.id
                        plate.isArtboard = true
                        plate.frame = l.frame
                        plate.name = l.name
                        plate.style.fills = [Fill(paint: .color(bg))]
                        var bgDrawable = Drawable(path: rect, style: plate.style, layer: plate, transform: t)
                        bgDrawable.isArtboardBackground = true
                        bgDrawable.includeInExport = l.backgroundInExport
                        out.append(bgDrawable)
                    }
                    inner = inner.map { var d = $0; d.clip = intersect(d.clip, rect); return d }
                }
                if let m = mask { inner = inner.map { var d = $0; d.clip = intersect(d.clip, m); return d } }
                if l.style.opacity != 1 {
                    inner = inner.map { var d = $0; d.opacity *= l.style.opacity; return d }
                }
                // Artboards don't cast shadows: a board is the page, not a thing on
                // it. Files can still carry one (Sketch allowed it) — ignoring it
                // here removes it from the canvas, PNG and SVG alike.
                if !l.style.shadows.isEmpty, !inner.isEmpty, !l.isArtboard {
                    var open = Drawable(path: nil, style: l.style, layer: l, transform: t)
                    open.groupShadows = l.style.shadows
                    var close = Drawable(path: nil, style: Style(), layer: l, transform: t)
                    close.endsGroup = true
                    out.append(open)
                    out.append(contentsOf: inner)
                    out.append(close)
                } else {
                    out.append(contentsOf: inner)
                }

            case .shapeGroup, .path:
                guard let p = resolvedPath(l) else { continue }
                var d = Drawable(path: p.transformed(by: t), style: l.style, layer: l, transform: t)
                d.clip = mask
                d.opacity = l.style.opacity
                out.append(d)

            case .text(let run):
                var d = Drawable(path: nil, style: l.style, layer: l, transform: t)
                d.text = run
                d.clip = mask
                d.opacity = l.style.opacity
                out.append(d)

            case .bitmap(let ref):
                var d = Drawable(path: nil, style: l.style, layer: l, transform: t)
                d.imageRef = ref
                d.clip = mask
                d.opacity = l.style.opacity
                out.append(d)
            }
        }
        return out
    }

    private static func intersect(_ a: CGPath?, _ b: CGPath) -> CGPath {
        guard let a else { return b }
        return a.intersection(b)
    }

    /// The bounds of what a layer actually paints, in its parent's space.
    ///
    /// A group's `frame` is the union of everything inside it — including the parts a
    /// clipping mask hides. Selection handles and the W/H fields describing a masked
    /// photo with the unmasked numbers read as a bug, so this walks the same drawables
    /// the renderer paints and intersects each with its clip before unioning.
    public static func visibleBounds(of layer: Layer, base: CGAffineTransform = .identity) -> CGRect {
        var r = CGRect.null
        for d in flatten([layer], base: base) where !d.isMarker {
            var b: CGRect
            if let p = d.path {
                b = p.boundingBoxOfPath
            } else {
                b = CGRect(origin: .zero, size: d.layer.frame.size).applying(d.transform)
            }
            if let c = d.clip { b = b.intersection(c.boundingBoxOfPath) }
            guard !b.isNull, !b.isEmpty else { continue }
            r = r.union(b)
        }
        guard !r.isNull else {
            // Nothing painted (hidden layer, empty group): fall back to the frame.
            return CGRect(origin: .zero, size: layer.frame.size)
                .applying(transform(layer).concatenating(base))
        }
        return r
    }
}

extension CGPath {
    /// CoreGraphics only offers `copy(using:)` with a pointer; this is the same thing
    /// with a signature you can chain.
    public func transformed(by t: CGAffineTransform) -> CGPath {
        var t = t
        return copy(using: &t) ?? self
    }
}

public struct Drawable {
    public var path: CGPath?
    public var style: Style
    public var layer: Layer
    public var transform: CGAffineTransform
    public var clip: CGPath?
    public var opacity: CGFloat = 1
    public var text: TextRun?
    public var imageRef: String?
    /// True for the plate painted behind an artboard, so exporters can honour
    /// "include background in export" without re-deriving it.
    public var isArtboardBackground = false
    public var includeInExport = true

    /// Brackets a group that carries a shadow.
    ///
    /// A group's shadow belongs to the silhouette of everything inside it, not to each
    /// child — put it on the children and you get a shadow cast onto the group's own
    /// members. The drawable list is flat, so the boundary is marked rather than
    /// nested: begin carries the shadows, end closes the range, and neither paints.
    public var groupShadows: [Shadow]?
    public var endsGroup = false

    /// Markers exist to bracket a range; they draw nothing themselves.
    public var isMarker: Bool { groupShadows != nil || endsGroup }
}
