import CoreGraphics
import Foundation

// Model -> SVG. This is the artifact that gets engraved, so it stays boring on purpose:
// plain <path> elements, no transforms on the elements themselves (geometry is baked),
// no <text>, no external references.

public struct SVGWriter {

    /// How placed bitmaps are referenced.
    ///
    /// `.embed` makes each SVG standalone — copy it anywhere and it still works. That's
    /// what a standalone `acmplc svg` export wants.
    ///
    /// `.link` points at a sibling path instead. Only safe when something guarantees the
    /// assets travel alongside — which is exactly true inside an `.acmplc.png`, where
    /// both live in the same ZIP. Embedding there would duplicate every bitmap into
    /// every page that uses it.
    public enum AssetMode {
        case embed
        case link(prefix: String)
    }

    public var images: [String: Data] = [:]
    public var assetMode: AssetMode = .embed

    public init(images: [String: Data] = [:], assetMode: AssetMode = .embed) {
        self.images = images
        self.assetMode = assetMode
    }

    public func svg(page: Page, bounds explicit: CGRect? = nil) -> String {
        let b = explicit ?? page.contentBounds()
        let drawables = Compose.flatten(page.layers)

        var body = "", defs = ""
        var clipID = 0

        for d in drawables {
            var attrs = ""
            if let clip = d.clip {
                clipID += 1
                defs += "  <clipPath id=\"c\(clipID)\"><path d=\"\(pathData(clip))\"/></clipPath>\n"
                attrs += " clip-path=\"url(#c\(clipID))\""
            }
            if d.opacity != 1 { attrs += " opacity=\"\(fmt(d.opacity))\"" }

            if let run = d.text {
                guard let p = TextOutline.path(run, in: CGRect(origin: .zero, size: d.layer.frame.size)) else { continue }
                let world = p.transformed(by: d.transform)
                let fill = d.style.fills.first.map { paintFill($0, &defs) } ?? ("fill=\"\(run.color.hex)\"", "")
                body += "  <path\(attrs) \(fill.0) d=\"\(pathData(world))\"/>\n"
                continue
            }

            if let ref = d.imageRef, images[ref] != nil {
                let r = d.layer.frame
                let m = d.transform
                let t = "matrix(\(fmt(m.a)),\(fmt(m.b)),\(fmt(m.c)),\(fmt(m.d)),\(fmt(m.tx)),\(fmt(m.ty)))"
                let href: String
                switch assetMode {
                case .embed:
                    href = "data:image/png;base64,\(images[ref]!.base64EncodedString())"
                case .link(let prefix):
                    href = prefix + ref
                }
                body += "  <image\(attrs) transform=\"\(t)\" x=\"0\" y=\"0\" width=\"\(fmt(r.width))\" height=\"\(fmt(r.height))\" "
                body += "xlink:href=\"\(href)\"/>\n"
                continue
            }

            guard let p = d.path else { continue }
            let dstr = pathData(p)
            guard !dstr.isEmpty else { continue }

            if d.style.fills.isEmpty && d.style.borders.isEmpty {
                body += "  <path\(attrs) fill=\"none\" d=\"\(dstr)\"/>\n"
            }
            for f in d.style.fills {
                let (fillAttr, extraDefs) = paintFill(f, &defs)
                _ = extraDefs
                body += "  <path\(attrs) \(fillAttr) d=\"\(dstr)\"/>\n"
            }
            for b2 in d.style.borders {
                // Inside/outside strokes need a clip to fake the half we keep; SVG has
                // no equivalent of Sketch's border position, so double the width and clip.
                var strokeAttrs = "fill=\"none\" stroke=\"\(b2.color.hex)\""
                if b2.color.a != 1 { strokeAttrs += " stroke-opacity=\"\(fmt(b2.color.a))\"" }
                var w = b2.thickness
                var clipAttr = attrs
                if b2.position != .center {
                    clipID += 1
                    defs += "  <clipPath id=\"c\(clipID)\"><path d=\"\(dstr)\"/></clipPath>\n"
                    w *= 2
                    if b2.position == .inside {
                        clipAttr += " clip-path=\"url(#c\(clipID))\""
                    } else {
                        defs += "  <mask id=\"m\(clipID)\"><rect x=\"\(fmt(b.minX))\" y=\"\(fmt(b.minY))\" width=\"\(fmt(b.width))\" height=\"\(fmt(b.height))\" fill=\"white\"/><path d=\"\(dstr)\" fill=\"black\"/></mask>\n"
                        clipAttr += " mask=\"url(#m\(clipID))\""
                    }
                }
                strokeAttrs += " stroke-width=\"\(fmt(w))\""
                if !b2.dashPattern.isEmpty {
                    strokeAttrs += " stroke-dasharray=\"\(b2.dashPattern.map(fmt).joined(separator: " "))\""
                }
                body += "  <path\(clipAttr) \(strokeAttrs) d=\"\(dstr)\"/>\n"
            }
        }

        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"\n"
        s += "     width=\"\(fmt(b.width))\" height=\"\(fmt(b.height))\"\n"
        s += "     viewBox=\"\(fmt(b.minX)) \(fmt(b.minY)) \(fmt(b.width)) \(fmt(b.height))\">\n"
        if !defs.isEmpty { s += "  <defs>\n\(defs)  </defs>\n" }
        s += body
        s += "</svg>\n"
        return s
    }

    private func paintFill(_ f: Fill, _ defs: inout String) -> (String, String) {
        switch f.paint {
        case .color(let c):
            var a = "fill=\"\(c.hex)\""
            let alpha = c.a * f.opacity
            if alpha != 1 { a += " fill-opacity=\"\(fmt(alpha))\"" }
            return (a, "")
        case .gradient(let g):
            let id = "g\(abs(defs.hashValue &* 31 &+ defs.count))"
            var def = ""
            let stops = g.stops.map {
                "      <stop offset=\"\(fmt($0.position))\" stop-color=\"\($0.color.hex)\" stop-opacity=\"\(fmt($0.color.a))\"/>\n"
            }.joined()
            switch g.kind {
            case .radial:
                let r = hypot(g.to.x - g.from.x, g.to.y - g.from.y)
                def = "  <radialGradient id=\"\(id)\" gradientUnits=\"objectBoundingBox\" cx=\"\(fmt(g.from.x))\" cy=\"\(fmt(g.from.y))\" r=\"\(fmt(r))\">\n\(stops)  </radialGradient>\n"
            default:
                // Angular gradients have no SVG equivalent; a linear ramp is the honest fallback.
                def = "  <linearGradient id=\"\(id)\" gradientUnits=\"objectBoundingBox\" x1=\"\(fmt(g.from.x))\" y1=\"\(fmt(g.from.y))\" x2=\"\(fmt(g.to.x))\" y2=\"\(fmt(g.to.y))\">\n\(stops)  </linearGradient>\n"
            }
            defs += def
            return ("fill=\"url(#\(id))\"", def)
        }
    }

    public func pathData(_ p: CGPath) -> String {
        var d = ""
        p.applyWithBlock { e in
            let pts = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint:     d += "M\(fmt(pts[0].x)) \(fmt(pts[0].y))"
            case .addLineToPoint:  d += "L\(fmt(pts[0].x)) \(fmt(pts[0].y))"
            case .addQuadCurveToPoint:
                d += "Q\(fmt(pts[0].x)) \(fmt(pts[0].y)) \(fmt(pts[1].x)) \(fmt(pts[1].y))"
            case .addCurveToPoint:
                d += "C\(fmt(pts[0].x)) \(fmt(pts[0].y)) \(fmt(pts[1].x)) \(fmt(pts[1].y)) \(fmt(pts[2].x)) \(fmt(pts[2].y))"
            case .closeSubpath:    d += "Z"
            @unknown default: break
            }
        }
        return d
    }
}

/// Three decimals: below engraver resolution, and keeps files small.
func fmt(_ v: CGFloat) -> String {
    if v == v.rounded() && abs(v) < 1e9 { return String(Int(v)) }
    return String(format: "%.3f", v)
}
