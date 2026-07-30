import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Model -> raster, via CoreGraphics. Shares Compose with the SVG writer, so the
// preview and the engraving file can't drift apart.

public struct Renderer {

    public var images: [String: Data] = [:]
    public var background: Color?
    public init(images: [String: Data] = [:], background: Color? = nil) {
        self.images = images
        self.background = background
    }

    /// `adjusting` and `live` preview a move or resize, exactly as the canvas does
    /// mid-gesture. Exposed so a test can render what you'd actually be looking at
    /// while dragging, rather than the state either side of it.
    public func render(page: Page, maxDimension: CGFloat = 1024, bounds explicit: CGRect? = nil,
                       adjusting: Set<String> = [], live: CGAffineTransform = .identity) -> CGImage? {
        let b = explicit ?? page.contentBounds()
        guard b.width > 0, b.height > 0 else { return nil }
        let scale = min(maxDimension / b.width, maxDimension / b.height, 4)
        let w = max(1, Int((b.width * scale).rounded()))
        let h = max(1, Int((b.height * scale).rounded()))

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        if let bg = background {
            ctx.setFillColor(bg.cg)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }

        // Flip into Sketch's y-down space and align the page bounds to the origin.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        if adjusting.isEmpty {
            draw(page: page, in: ctx)
        } else {
            draw(drawables: Compose.flatten(page.layers, adjusting: adjusting, live: live), in: ctx)
        }
        return ctx.makeImage()
    }

    /// Draws into a context already set up in the page's own coordinate space (y-down).
    /// The editor's canvas view calls this directly, so what's on screen and what gets
    /// exported come out of exactly the same code.
    public func draw(page: Page, in ctx: CGContext) {
        draw(drawables: Compose.flatten(page.layers), in: ctx)
    }

    /// Draws an already-composed drawable list.
    ///
    /// Composition runs every shapeGroup's children through CGPath boolean ops, which
    /// costs ~0.6s on a busy coin page. An interactive canvas redraws on every scroll
    /// and zoom tick, so it must flatten once per page and reuse the result — not
    /// recompute it per frame.
    public func draw(drawables: [Drawable], in ctx: CGContext) {
        var i = 0
        while i < drawables.count {
            let d = drawables[i]
            if let shadows = d.groupShadows, let close = Self.matchingEnd(drawables, from: i) {
                let inner = Array(drawables[(i + 1)..<close])
                // One pass per shadow, each drawing the group inside a transparency
                // layer so the shadow comes from the combined silhouette. The last pass
                // leaves the artwork on top. Stacked passes redraw the content, which
                // is invisible for opaque art and would deepen translucent art — the
                // trade for supporting more than one shadow at all.
                for s in shadows {
                    ctx.saveGState()
                    ctx.setShadow(offset: s.offset, blur: s.blur, color: s.color.cg)
                    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                    for c in inner where !c.isMarker { draw(c, in: ctx) }
                    ctx.endTransparencyLayer()
                    ctx.restoreGState()
                }
                i = close + 1
                continue
            }
            if !d.isMarker { draw(d, in: ctx) }
            i += 1
        }
    }

    /// Index of the marker closing the group opened at `start`, allowing for nesting.
    private static func matchingEnd(_ ds: [Drawable], from start: Int) -> Int? {
        var depth = 0
        var i = start
        while i < ds.count {
            if ds[i].groupShadows != nil { depth += 1 }
            if ds[i].endsGroup {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// Hit-test: the topmost drawable whose geometry contains `point` (page space).
    public func hitTest(page: Page, at point: CGPoint) -> Layer? {
        for d in Compose.flatten(page.layers).reversed() {
            if let p = d.path, p.contains(point) { return d.layer }
            if d.path == nil {
                let f = d.layer.frame
                let local = CGRect(origin: .zero, size: f.size).applying(d.transform)
                if local.contains(point) { return d.layer }
            }
        }
        return nil
    }

    private func draw(_ d: Drawable, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        if let clip = d.clip {
            ctx.addPath(clip)
            ctx.clip()
        }
        if d.opacity != 1 { ctx.setAlpha(d.opacity) }

        if let ref = d.imageRef, let data = images[ref], let o = BitmapImage.load(data) {
            ctx.saveGState()
            ctx.concatenate(d.transform)
            let r = CGRect(origin: .zero, size: d.layer.frame.size)

            // Erase strokes clip the image rather than altering it. Built at twice the
            // layer size so a soft edge stays soft when you zoom in.
            if !d.layer.erased.isEmpty,
               let mask = EraseMask.image(strokes: d.layer.erased, size: r.size) {
                ctx.clip(to: r, mask: mask)
            }

            // Adjusted or cropped: the baked image arrives already in display
            // orientation, so it draws with a plain flip.
            if d.layer.hasBitmapAdjustments,
               let baked = BitmapAdjust.displayImage(data: data, ref: ref, layer: d.layer) {
                ctx.scaleBy(x: r.width / max(1, CGFloat(baked.width)),
                            y: r.height / max(1, CGFloat(baked.height)))
                ctx.translateBy(x: 0, y: CGFloat(baked.height))
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(baked, in: CGRect(x: 0, y: 0, width: baked.width, height: baked.height))
                ctx.restoreGState()
                return
            }

            // Order is load-bearing. The EXIF transform is defined in y-DOWN display
            // space, so it has to be applied while we're still in that space. Flipping
            // first (for CGImage's y-up drawing) and rotating after mirrors the result.
            //   layer frame -> display box -> native pixels -> flip -> draw
            ctx.scaleBy(x: r.width / max(1, o.displaySize.width),
                        y: r.height / max(1, o.displaySize.height))
            ctx.concatenate(o.transform)
            ctx.translateBy(x: 0, y: o.nativeSize.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img: o.image, size: o.nativeSize)
            ctx.restoreGState()
            return
        }

        var path: CGPath?
        if let run = d.text {
            path = TextOutline.path(run, in: CGRect(origin: .zero, size: d.layer.frame.size))?
                .transformed(by: d.transform)
            if d.style.fills.isEmpty, let p = path {
                ctx.addPath(p)
                ctx.setFillColor(run.color.cg)
                ctx.fillPath()
                return
            }
        } else {
            path = d.path
        }
        guard let p = path else { return }

        for s in d.style.shadows {
            ctx.saveGState()
            ctx.setShadow(offset: s.offset, blur: s.blur, color: s.color.cg)
            ctx.addPath(p)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }

        for f in d.style.fills {
            switch f.paint {
            case .color(let c):
                ctx.addPath(p)
                ctx.setFillColor(c.cg.copy(alpha: c.a * f.opacity) ?? c.cg)
                ctx.fillPath()
            case .gradient(let g):
                ctx.saveGState()
                ctx.addPath(p)
                ctx.clip()
                drawGradient(g, in: p.boundingBoxOfPath, ctx: ctx, alpha: f.opacity)
                ctx.restoreGState()
            }
        }

        for b in d.style.borders {
            ctx.saveGState()
            if b.position != .center {
                ctx.addPath(p)
                if b.position == .inside {
                    ctx.clip()
                } else {
                    ctx.addRect(CGRect(infinite: true))
                    ctx.clip(using: .evenOdd)
                }
            }
            ctx.addPath(p)
            ctx.setStrokeColor(b.color.cg)
            ctx.setLineWidth(b.position == .center ? b.thickness : b.thickness * 2)
            if !b.dashPattern.isEmpty { ctx.setLineDash(phase: 0, lengths: b.dashPattern) }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func drawGradient(_ g: Gradient, in r: CGRect, ctx: CGContext, alpha: CGFloat) {
        let colors = g.stops.map { $0.color.cg.copy(alpha: $0.color.a * alpha) ?? $0.color.cg } as CFArray
        let locs = g.stops.map { $0.position }
        guard let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    colors: colors, locations: locs) else { return }
        let p0 = CGPoint(x: r.minX + g.from.x * r.width, y: r.minY + g.from.y * r.height)
        let p1 = CGPoint(x: r.minX + g.to.x * r.width, y: r.minY + g.to.y * r.height)
        switch g.kind {
        case .radial:
            ctx.drawRadialGradient(grad, startCenter: p0, startRadius: 0, endCenter: p0,
                                   endRadius: hypot(p1.x - p0.x, p1.y - p0.y),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        default:
            ctx.drawLinearGradient(grad, start: p0, end: p1,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    public static func jpeg(_ image: CGImage, quality: CGFloat = 0.9) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    public static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

extension CGRect {
    init(infinite: Bool) { self = CGRect(x: -1e7, y: -1e7, width: 2e7, height: 2e7) }
}

extension CGContext {
    func draw(img: CGImage, size: CGSize) {
        draw(img, in: CGRect(origin: .zero, size: size))
    }
}
