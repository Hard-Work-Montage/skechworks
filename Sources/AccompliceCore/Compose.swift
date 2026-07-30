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

    /// The layer's outline in its OWN local space, with all boolean ops applied.
    /// Returns nil for anything that isn't a shape (text, bitmaps, plain groups).
    public static func resolvedPath(_ l: Layer) -> CGPath? {
        switch l.kind {
        case .path(let p, _):
            // The one place a corner radius turns into geometry. Everything downstream
            // — the renderer, the SVG writer, boolean ops, masks, hit-testing — reads
            // the shape through here, so none of them has to know the radius exists.
            guard l.cornerRadius > 0 else { return p }
            return Corners.round(p, radius: l.cornerRadius, style: l.cornerStyle)

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
        for c in children where c.isVisible {
            guard let raw = resolvedPath(c) else { continue }
            let p = raw.transformed(by: transform(c))
            guard let a = acc else { acc = p; continue }
            switch c.booleanOp {
            case .none:
                // No op: just another subpath. The winding rule decides what fills —
                // this is how Sketch stores a ring as two concentric circles.
                let m = CGMutablePath()
                m.addPath(a); m.addPath(p)
                acc = m.copy()
            case .union:      acc = a.union(p, using: rule)
            case .subtract:   acc = a.subtracting(p, using: rule)
            case .intersect:  acc = a.intersection(p, using: rule)
            case .difference: acc = a.symmetricDifference(p, using: rule)
            }
        }
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
