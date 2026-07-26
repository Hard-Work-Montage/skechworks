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
            return p

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
    public static func flatten(_ layers: [Layer], base: CGAffineTransform = .identity) -> [Drawable] {
        var out: [Drawable] = []
        var mask: CGPath?

        for l in layers where l.isVisible {
            let t = transform(l).concatenating(base)

            if l.breaksMaskChain { mask = nil }

            if l.hasClippingMask, let p = resolvedPath(l) {
                mask = p.transformed(by: t)
                continue   // the mask layer itself isn't painted
            }

            switch l.kind {
            case .group(let kids):
                var inner = flatten(kids, base: t)
                if let m = mask { inner = inner.map { var d = $0; d.clip = intersect(d.clip, m); return d } }
                if l.style.opacity != 1 {
                    inner = inner.map { var d = $0; d.opacity *= l.style.opacity; return d }
                }
                out.append(contentsOf: inner)

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
}
