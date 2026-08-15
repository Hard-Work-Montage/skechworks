import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Model -> raster, via CoreGraphics. Shares Compose with the SVG writer, so the
// preview and the engraving file can't drift apart.

public struct Renderer {

    public var images: [String: Data] = [:]
    public var background: Color?
    /// Honors each artboard's "include fill in export", dropping the plate a board
    /// says not to hand on. SVG has always done this and PNG never did, so the
    /// same checkbox gave a transparent SVG and a PNG with the white still baked
    /// in — from the same board, in the same export panel.
    ///
    /// Off by default, because most renders here are not exports. The cover
    /// thumbnail inside a document and the picture a model is shown both want the
    /// board as it looks, and a board that disappears in either is a picture with
    /// a hole in it.
    public var honorsExportFlags = false
    public init(images: [String: Data] = [:], background: Color? = nil,
                honorsExportFlags: Bool = false) {
        self.images = images
        self.background = background
        self.honorsExportFlags = honorsExportFlags
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
    /// `visible` culls drawables whose bounds sit entirely outside it — the canvas
    /// passes its viewport so a zoomed-in redraw of a 5,000-path page only
    /// rasterizes what's on screen. Exports pass nothing and draw everything.
    public func draw(drawables: [Drawable], in ctx: CGContext, visible: CGRect? = nil) {
        var i = 0
        while i < drawables.count {
            let d = drawables[i]
            if let v = visible, !d.isMarker, d.groupShadows == nil,
               !Self.roughBounds(of: d).intersects(v) {
                i += 1
                continue
            }
            // The one drawable an export is allowed to leave out, and only when
            // the board it belongs to asked. Same rule SVGWriter follows.
            if honorsExportFlags, d.isArtboardBackground, !d.includeInExport {
                i += 1
                continue
            }
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

    /// A drawable's page-space bounds, generously padded for what draws outside the
    /// geometry: strokes, shadows, and text that overruns its frame. Culling only —
    /// too big is a few wasted paths, too small is artwork missing at the edges.
    static func roughBounds(of d: Drawable) -> CGRect {
        var b: CGRect
        if let p = d.path { b = p.boundingBoxOfPath }
        else { b = CGRect(origin: .zero, size: d.layer.frame.size).applying(d.transform) }
        if let c = d.clip { b = b.intersection(c.boundingBoxOfPath) }
        var grow: CGFloat = 2
        for border in d.style.borders {
            grow = max(grow, border.thickness * 2)
        }
        for s in d.style.shadows {
            grow = max(grow, s.blur + max(abs(s.offset.width), abs(s.offset.height)))
        }
        if d.text != nil { grow = max(grow, 100) }
        return b.insetBy(dx: -grow, dy: -grow)
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

    /// Whether a point lands on a path counting its STROKE: an open five-pixel
    /// line has no fill to contain anything, and clicking it selected whatever
    /// sat behind. The outline is the stroke width or the slop, whichever is
    /// more forgiving.
    public static func pathHit(_ p: CGPath, at point: CGPoint,
                               borders: [Border], slop: CGFloat) -> Bool {
        if p.contains(point) { return true }
        let stroke = borders.map(\.thickness).max() ?? 0
        let outline = p.copy(strokingWithWidth: max(stroke, slop * 2),
                             lineCap: .round, lineJoin: .round, miterLimit: 10)
        return outline.contains(point)
    }

    /// Hit-test: the topmost drawable whose geometry contains `point` (page space).
    public func hitTest(page: Page, at point: CGPoint) -> Layer? {
        for d in Compose.flatten(page.layers).reversed() {
            if let p = d.path,
               Renderer.pathHit(p, at: point, borders: d.style.borders, slop: 3) {
                return d.layer
            }
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

            // Perspective warp: bake the display image (orientation, adjustments,
            // crop) and project it onto the corner quad. The warped picture can
            // spill outside the frame — that's the point of dragging a corner out.
            if d.layer.warpCorners != nil,
               let (warped, unitBox) = BitmapWarp.warpedDisplayImage(data: data, ref: ref, layer: d.layer) {
                let box = CGRect(x: unitBox.minX * r.width, y: unitBox.minY * r.height,
                                 width: unitBox.width * r.width, height: unitBox.height * r.height)
                ctx.translateBy(x: box.minX, y: box.minY)
                ctx.scaleBy(x: box.width / max(1, CGFloat(warped.width)),
                            y: box.height / max(1, CGFloat(warped.height)))
                ctx.translateBy(x: 0, y: CGFloat(warped.height))
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(warped, in: CGRect(x: 0, y: 0, width: warped.width, height: warped.height))
                ctx.restoreGState()
                return
            }

            // Erase strokes clip the image rather than altering it. Built at twice the
            // layer size so a soft edge stays soft when you zoom in.
            //
            // clip(to:mask:) shares draw(_:in:)'s orientation rules, and this space is
            // y-down — apply it un-flipped and the holes land mirrored, which reads as
            // "erase does nothing" whenever the mirrored spot is already transparent.
            // Flip around the layer box just for the clip; the region itself is stored
            // in device space, so it survives the flip back.
            if !d.layer.erased.isEmpty,
               let mask = EraseMask.image(strokes: d.layer.erased, size: r.size) {
                ctx.translateBy(x: 0, y: r.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.clip(to: r, mask: mask)
                ctx.scaleBy(x: 1, y: -1)
                ctx.translateBy(x: 0, y: -r.height)
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
            ctx.setLineCap(CGLineCap(rawValue: Int32(b.cap.rawValue)) ?? .butt)
            ctx.setLineJoin(CGLineJoin(rawValue: Int32(b.join.rawValue)) ?? .miter)
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
