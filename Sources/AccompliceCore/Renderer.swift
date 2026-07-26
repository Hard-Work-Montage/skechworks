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

    public func render(page: Page, maxDimension: CGFloat = 1024, bounds explicit: CGRect? = nil) -> CGImage? {
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

        draw(page: page, in: ctx)
        return ctx.makeImage()
    }

    /// Draws into a context already set up in the page's own coordinate space (y-down).
    /// The editor's canvas view calls this directly, so what's on screen and what gets
    /// exported come out of exactly the same code.
    public func draw(page: Page, in ctx: CGContext) {
        for d in Compose.flatten(page.layers) { draw(d, in: ctx) }
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

        if let ref = d.imageRef, let data = images[ref],
           let src = CGImageSourceCreateWithData(data as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            ctx.saveGState()
            ctx.concatenate(d.transform)
            let r = CGRect(origin: .zero, size: d.layer.frame.size)
            // Undo the y-flip locally so the bitmap isn't drawn upside down.
            ctx.translateBy(x: 0, y: r.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: r)
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
