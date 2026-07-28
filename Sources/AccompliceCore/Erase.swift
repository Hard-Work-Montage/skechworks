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

    public init(points: [CGPoint], radius: CGFloat, softness: CGFloat = 0.5) {
        self.points = points
        self.radius = max(0.5, radius)
        self.softness = min(1, max(0, softness))
    }

    /// How far the stroke reaches, for invalidation and for sizing the mask.
    public var bounds: CGRect {
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

        for stroke in strokes { stamp(stroke, in: ctx) }
        return ctx.makeImage()
    }

    /// Draws one stroke as a run of overlapping soft stamps.
    ///
    /// Stamping rather than stroking a path: a soft edge is a gradient per dab, and a
    /// stroked line can only have one colour. Spacing is a quarter of the radius,
    /// which is close enough that the dabs read as a line rather than a string of
    /// beads, without costing a stamp per pixel.
    private static func stamp(_ stroke: EraseStroke, in ctx: CGContext) {
        let spacing = max(0.5, stroke.radius / 4)
        var dabs: [CGPoint] = []
        if stroke.points.count == 1 {
            dabs = stroke.points
        } else {
            for i in 1..<stroke.points.count {
                let a = stroke.points[i - 1], b = stroke.points[i]
                let d = hypot(b.x - a.x, b.y - a.y)
                let steps = max(1, Int((d / spacing).rounded(.up)))
                for s in 0...steps {
                    let t = CGFloat(s) / CGFloat(steps)
                    dabs.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                }
            }
        }

        let solid = 1 - stroke.softness      // the fraction of the radius left hard
        for p in dabs {
            if stroke.softness <= 0.001 {
                ctx.setFillColor(gray: 0, alpha: 1)
                ctx.fillEllipse(in: CGRect(x: p.x - stroke.radius, y: p.y - stroke.radius,
                                           width: stroke.radius * 2, height: stroke.radius * 2))
                continue
            }
            let space = CGColorSpaceCreateDeviceGray()
            guard let gradient = CGGradient(colorsSpace: space,
                                            colors: [CGColor(gray: 0, alpha: 1),
                                                     CGColor(gray: 0, alpha: 0)] as CFArray,
                                            locations: [solid, 1]) else { continue }
            ctx.saveGState()
            ctx.setBlendMode(.multiply)      // overlapping dabs deepen rather than reset
            ctx.drawRadialGradient(gradient, startCenter: p, startRadius: 0,
                                   endCenter: p, endRadius: stroke.radius,
                                   options: .drawsAfterEndLocation)
            ctx.restoreGState()
        }
    }
}
