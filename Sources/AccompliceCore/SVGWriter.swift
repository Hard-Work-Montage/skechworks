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

        // Everything is written relative to the export box, so the file starts at
        // 0,0 rather than wherever the artwork happened to sit on the canvas.
        //
        // Emitting the box's own origin as the viewBox produces a valid file that
        // previews correctly — the camera is moved to match — but the offset then
        // lives on the <svg> element rather than in the geometry. Any consumer that
        // lifts the paths onto its own canvas loses it, and the artwork lands
        // off-screen with nothing reporting a problem. The Achieve Mint's coin
        // templates do exactly that: a background exported at viewBox="2374 0 500
        // 500" looked right in their editor and engraved as a blank disc.
        let origin = CGAffineTransform(translationX: -b.minX, y: -b.minY)

        var body = "", defs = ""
        var clipID = 0
        var filterID = 0
        var openGroups = 0

        for d in drawables {
            // A group's shadow becomes an SVG filter around the range, rather than
            // being dropped on the floor. feDropShadow is the direct equivalent and
            // works from the combined silhouette, exactly as it does on canvas.
            if let shadows = d.groupShadows {
                filterID += 1
                let parts = shadows.map { s in
                    "<feDropShadow dx=\"\(fmt(s.offset.width))\" dy=\"\(fmt(s.offset.height))\" "
                        + "stdDeviation=\"\(fmt(s.blur / 2))\" flood-color=\"\(s.color.hex)\" "
                        + "flood-opacity=\"\(fmt(s.color.a))\"/>"
                }.joined()
                defs += "  <filter id=\"s\(filterID)\" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\">\(parts)</filter>\n"
                body += "  <g filter=\"url(#s\(filterID))\">\n"
                openGroups += 1
                continue
            }
            if d.endsGroup {
                if openGroups > 0 { body += "  </g>\n"; openGroups -= 1 }
                continue
            }
            // An artboard background that Sketch marks as export-excluded must not be
            // baked into the engraving file.
            if d.isArtboardBackground && !d.includeInExport { continue }
            var attrs = ""
            if let clip = d.clip, !clipsNothing(clip, around: d) {
                clipID += 1
                // The clip arrives in document coordinates like everything else, so it
                // needs the same shift into the export box. Without it the clip stays at
                // the artboard's place on the canvas while the art moves to 0,0, and an
                // artboard anywhere but the origin exports a blank file.
                var clipT = origin
                let placedClip = clip.copy(using: &clipT) ?? clip
                defs += "  <clipPath id=\"c\(clipID)\"><path d=\"\(pathData(placedClip))\"/></clipPath>\n"
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

            if let ref = d.imageRef, let data = images[ref] {
                let r = d.layer.frame
                // SVG has no perspective transform for images at all, so a warped
                // bitmap is projected first and the warped raster is embedded at
                // its bounding box.
                if d.layer.warpCorners != nil,
                   let (warped, unitBox) = BitmapWarp.warpedDisplayImage(data: data, ref: ref, layer: d.layer),
                   let png = Renderer.png(warped) {
                    let box = CGRect(x: unitBox.minX * r.width, y: unitBox.minY * r.height,
                                     width: unitBox.width * r.width, height: unitBox.height * r.height)
                    var m = CGAffineTransform(translationX: box.minX, y: box.minY)
                        .scaledBy(x: box.width / max(1, CGFloat(warped.width)),
                                  y: box.height / max(1, CGFloat(warped.height)))
                    m = m.concatenating(d.transform).concatenating(origin)
                    let t = "matrix(\(fmt(m.a)),\(fmt(m.b)),\(fmt(m.c)),\(fmt(m.d)),\(fmt(m.tx)),\(fmt(m.ty)))"
                    body += "  <image\(attrs) transform=\"\(t)\" x=\"0\" y=\"0\" width=\"\(warped.width)\" height=\"\(warped.height)\" "
                    body += "xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/>\n"
                    continue
                }
                // Adjustments and crops can't be expressed portably in SVG, so a
                // touched bitmap is baked and embedded — the untouched path below
                // keeps original bytes exactly as they were.
                if d.layer.hasBitmapAdjustments,
                   let baked = BitmapAdjust.displayImage(data: data, ref: ref, layer: d.layer),
                   let png = BitmapAdjust.pngData(data: data, ref: ref, layer: d.layer) {
                    var m = CGAffineTransform(scaleX: r.width / max(1, CGFloat(baked.width)),
                                              y: r.height / max(1, CGFloat(baked.height)))
                    m = m.concatenating(d.transform).concatenating(origin)
                    let t = "matrix(\(fmt(m.a)),\(fmt(m.b)),\(fmt(m.c)),\(fmt(m.d)),\(fmt(m.tx)),\(fmt(m.ty)))"
                    body += "  <image\(attrs) transform=\"\(t)\" x=\"0\" y=\"0\" width=\"\(baked.width)\" height=\"\(baked.height)\" "
                    body += "xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/>\n"
                    continue
                }
                // SVG renderers don't reliably honour EXIF orientation, so bake it into
                // the element transform instead of re-encoding the image. Original bytes
                // stay exactly as they were.
                let o = BitmapImage.load(data)
                let display = o?.displaySize ?? r.size
                let native = o?.nativeSize ?? r.size
                var m = CGAffineTransform(scaleX: r.width / max(1, display.width),
                                          y: r.height / max(1, display.height))
                if let o { m = o.transform.concatenating(m) }
                m = m.concatenating(d.transform).concatenating(origin)
                let t = "matrix(\(fmt(m.a)),\(fmt(m.b)),\(fmt(m.c)),\(fmt(m.d)),\(fmt(m.tx)),\(fmt(m.ty)))"
                let href: String
                switch assetMode {
                case .embed:
                    href = "data:image/png;base64,\(data.base64EncodedString())"
                case .link(let prefix):
                    href = prefix + ref
                }
                body += "  <image\(attrs) transform=\"\(t)\" x=\"0\" y=\"0\" width=\"\(fmt(native.width))\" height=\"\(fmt(native.height))\" "
                body += "xlink:href=\"\(href)\"/>\n"
                continue
            }

            guard let p = d.path else { continue }
            // Anything with a stroke keeps its hairlines: they are lines.
            var originT = origin
            let placed = p.copy(using: &originT) ?? p
            let dstr = pathData(placed, dropSlivers: d.style.borders.isEmpty)
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
                        defs += "  <mask id=\"m\(clipID)\"><rect x=\"0\" y=\"0\" width=\"\(fmt(b.width))\" height=\"\(fmt(b.height))\" fill=\"white\"/><path d=\"\(dstr)\" fill=\"black\"/></mask>\n"
                        clipAttr += " mask=\"url(#m\(clipID))\""
                    }
                }
                strokeAttrs += " stroke-width=\"\(fmt(w))\""
                if !b2.dashPattern.isEmpty {
                    strokeAttrs += " stroke-dasharray=\"\(b2.dashPattern.map(fmt).joined(separator: " "))\""
                }
                if b2.cap != .butt {
                    strokeAttrs += " stroke-linecap=\"\(b2.cap == .round ? "round" : "square")\""
                }
                if b2.join != .miter {
                    strokeAttrs += " stroke-linejoin=\"\(b2.join == .round ? "round" : "bevel")\""
                }
                body += "  <path\(clipAttr) \(strokeAttrs) d=\"\(dstr)\"/>\n"
            }
        }

        // A truncated tree would produce invalid SVG; close anything still open.
        while openGroups > 0 { body += "  </g>\n"; openGroups -= 1 }

        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"\n"
        s += "     width=\"\(fmt(b.width))\" height=\"\(fmt(b.height))\"\n"
        s += "     viewBox=\"0 0 \(fmt(b.width)) \(fmt(b.height))\">\n"
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

    /// `dropSlivers` culls hairline contours. Right for something that is filled,
    /// where a contour with no thickness paints nothing; wrong for something that
    /// is stroked, where a subpath of zero height is a perfectly ordinary straight
    /// line. Exporting a horizontal line produced an empty SVG for exactly this
    /// reason: min(width, height) of a flat line is 0, so it read as a sliver.
    /// Whether a clip would cut nothing off this drawable.
    ///
    /// Everything inside an artboard is clipped to the board's edge, which is
    /// right on a canvas and pointless in a file when the shape sits well
    /// inside it. Sketch turns every clip-path into a "Clipped" group holding a
    /// mask rectangle, so a drawing of ten shapes opened as ten nested groups
    /// with twenty paths — none of which the person drew.
    ///
    /// Conservative on both counts. Only a plain axis-aligned rectangle is
    /// dropped, because a shaped mask can cut a shape that sits entirely inside
    /// its bounding box. And the shape's ink is measured, not its path: half a
    /// stroke and any shadow reach past the outline, and those are exactly what
    /// a board edge is there to cut.
    func clipsNothing(_ clip: CGPath, around d: Drawable) -> Bool {
        let box = clip.boundingBoxOfPath
        guard !box.isNull, !box.isEmpty else { return false }
        // A rectangle and nothing else.
        guard clip == CGPath(rect: box, transform: nil) else { return false }

        var ink: CGRect
        if let p = d.path {
            ink = p.boundingBoxOfPath
        } else {
            // Text and images cover their frame.
            ink = CGRect(origin: .zero, size: d.layer.frame.size).applying(d.transform)
        }
        guard !ink.isNull, !ink.isInfinite else { return false }

        // Ink reaches past the outline: half a stroke either side, and a shadow
        // as far as its blur plus its offset.
        // An outside border reaches a full thickness past the outline, not half.
        let stroke = d.style.borders.map { $0.position == .center ? $0.thickness / 2 : $0.thickness }.max() ?? 0
        var slack = stroke
        for shadow in d.style.shadows {
            slack = max(slack, shadow.blur + shadow.spread
                        + max(abs(shadow.offset.width), abs(shadow.offset.height)))
        }
        return box.insetBy(dx: -0.01, dy: -0.01).contains(ink.insetBy(dx: -slack, dy: -slack))
    }

    public func pathData(_ p: CGPath, dropSlivers: Bool = true) -> String {
        // Serialized per subpath, so hairline contours can be dropped whole. Boolean
        // sweeps leave slivers thinner than anything a cutter can act on, and laser
        // software (LightBurn, at least) treats a zero-width filled contour as an
        // unclosed shape and strips it — with a scary warning per sliver. Anything
        // whose box is under 1/20 unit in either direction is below the writer's own
        // three-decimal resolution story, and invisible on screen.
        var subs: [(d: String, min: CGPoint, max: CGPoint)] = []
        var cur = ""
        var lo = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)
        var hi = CGPoint(x: -CGFloat.greatestFiniteMagnitude, y: -CGFloat.greatestFiniteMagnitude)
        func track(_ n: Int, _ pts: UnsafeMutablePointer<CGPoint>) {
            for i in 0..<n {
                lo.x = min(lo.x, pts[i].x); lo.y = min(lo.y, pts[i].y)
                hi.x = max(hi.x, pts[i].x); hi.y = max(hi.y, pts[i].y)
            }
        }
        func flush() {
            if !cur.isEmpty { subs.append((cur, lo, hi)) }
            cur = ""
            lo = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)
            hi = CGPoint(x: -CGFloat.greatestFiniteMagnitude, y: -CGFloat.greatestFiniteMagnitude)
        }
        p.applyWithBlock { e in
            let pts = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint:
                flush()
                cur += "M\(fmt(pts[0].x)) \(fmt(pts[0].y))"; track(1, pts)
            case .addLineToPoint:
                cur += "L\(fmt(pts[0].x)) \(fmt(pts[0].y))"; track(1, pts)
            case .addQuadCurveToPoint:
                cur += "Q\(fmt(pts[0].x)) \(fmt(pts[0].y)) \(fmt(pts[1].x)) \(fmt(pts[1].y))"; track(2, pts)
            case .addCurveToPoint:
                cur += "C\(fmt(pts[0].x)) \(fmt(pts[0].y)) \(fmt(pts[1].x)) \(fmt(pts[1].y)) \(fmt(pts[2].x)) \(fmt(pts[2].y))"; track(3, pts)
            case .closeSubpath:
                cur += "Z"
            @unknown default: break
            }
        }
        flush()
        guard dropSlivers else { return subs.map(\.d).joined() }
        return subs.filter { min($0.max.x - $0.min.x, $0.max.y - $0.min.y) >= 0.05 }
                   .map(\.d).joined()
    }
}

/// Three decimals: below engraver resolution, and keeps files small.
func fmt(_ v: CGFloat) -> String {
    if v == v.rounded() && abs(v) < 1e9 { return String(Int(v)) }
    return String(format: "%.3f", v)
}
