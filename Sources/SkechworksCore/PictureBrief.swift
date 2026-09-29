import CoreGraphics
import CoreText
import Foundation

/// What chat is shown of the picture it is working on: the picture itself,
/// with every choice it could make outlined and numbered.
///
/// The model is good at "which of these is the cloud" and bad at drawing an
/// edge. The tools here are the other way round. So the tools draw the edges,
/// and the model picks numbers off a picture:
///
/// - C, patches of the colour the wand sampled
/// - E, erases already on the picture, to put back
/// - S, the subjects macOS found, to keep
///
/// The numbers come from the same calls the commands make, in the same order,
/// so C3 on the picture is C3 in `eraseColor`.
public enum PictureBrief {

    public struct Made: Sendable {
        public var png: Data
        public var text: String
    }

    /// The longest side of the picture sent. Enough to tell a cloud from a
    /// letter; a full coin is four times this and costs four times as much.
    static let side: CGFloat = 1024

    public static func make(visible: CGImage, layer: Layer, name: String,
                            wandHex: String?) -> Made? {
        let w = CGFloat(visible.width), h = CGFloat(visible.height)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, side / max(w, h))
        let ow = Int((w * scale).rounded()), oh = Int((h * scale).rounded())
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Erased parts show as a check, so a model can see what is already gone.
        let cell = 12
        for y in stride(from: 0, to: oh, by: cell) {
            for x in stride(from: 0, to: ow, by: cell) {
                let light = ((x / cell) + (y / cell)) % 2 == 0
                ctx.setFillColor(gray(light ? 0.94 : 0.82))
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        ctx.draw(visible, in: CGRect(x: 0, y: 0, width: ow, height: oh))

        // Image pixels, y down, to this picture's space, y up.
        func place(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: CGFloat(oh) - p.y * scale) }
        func place(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * scale, y: CGFloat(oh) - r.maxY * scale, width: r.width * scale, height: r.height * scale)
        }
        func where_(_ box: CGRect) -> String {
            func pc(_ v: CGFloat, _ of: CGFloat) -> Int { Int((v / of * 100).rounded()) }
            return "\(pc(box.width, w))% wide, \(pc(box.height, h))% tall, centred \(pc(box.midX, w))% across and \(pc(box.midY, h))% down"
        }
        var lines: [String] = []
        lines.append("PICTURE: image “\(name)”, \(Int(w))×\(Int(h)) px. It is attached, with numbered outlines on it.")

        let magenta = CGColor(red: 1, green: 0, blue: 0.8, alpha: 1)
        let cyan = CGColor(red: 0, green: 0.75, blue: 1, alpha: 1)
        let lime = CGColor(red: 0.2, green: 0.9, blue: 0.1, alpha: 1)

        // What's already gone, to put back.
        if !layer.erased.isEmpty, layer.frame.width > 0, layer.frame.height > 0 {
            let sx = w / layer.frame.width, sy = h / layer.frame.height
            lines.append("")
            lines.append("E: erases already on it, in the order made. putBack takes these numbers.")
            for (i, stroke) in layer.erased.enumerated() {
                let b = stroke.bounds
                let box = CGRect(x: b.minX * sx, y: b.minY * sy, width: b.width * sx, height: b.height * sy)
                if let poly = stroke.polygon {
                    outline([poly] + stroke.holes, in: ctx, colour: cyan) { place(CGPoint(x: $0.x * sx, y: $0.y * sy)) }
                } else {
                    ctx.setStrokeColor(cyan); ctx.setLineWidth(2); ctx.stroke(place(box))
                }
                tag("E\(i + 1)", at: place(box), in: ctx, colour: cyan)
                lines.append("E\(i + 1): \(where_(box))")
            }
        }

        // Patches of the sampled colour.
        if let wandHex, let colour = SVGReader.color(wandHex, alpha: 1) {
            let found = KnockOut.patches(in: visible, color: colour, exact: true)
            lines.append("")
            if found.isEmpty {
                lines.append("C: the wand sampled \(wandHex) but no patch of it has an outline round it.")
            } else {
                lines.append("C: patches of the wand's colour \(wandHex). eraseColor with color \(wandHex), exact:true and patches:[numbers] erases exactly the ones you pick. Marked * are outlined enough to go without picking; pick for yourself from the picture, since a lit cloud or sunny grass can be outlined too.")
                for (i, patch) in found.enumerated() {
                    for piece in patch.pieces {
                        outline(piece, in: ctx, colour: magenta) { place($0) }
                    }
                    tag("C\(i + 1)", at: place(patch.box), in: ctx, colour: magenta)
                    let star = patch.outlined >= KnockOut.outlinedEnough ? " *" : ""
                    lines.append("C\(i + 1)\(star): \(where_(patch.box)), edge \(Int(patch.outlined * 100))% outlined")
                }
            }
        }

        // The things in it, to keep.
        let subjects = Subjects.find(in: visible)
        if !subjects.isEmpty {
            lines.append("")
            lines.append("S: subjects macOS lifted off the background, biggest first. keepSubjects takes these numbers and erases everything else.")
            for (i, s) in subjects.enumerated() {
                ctx.setStrokeColor(lime); ctx.setLineWidth(3); ctx.setLineDash(phase: 0, lengths: [10, 6])
                ctx.stroke(place(s.box).insetBy(dx: -2, dy: -2))
                ctx.setLineDash(phase: 0, lengths: [])
                // Bottom corner: a subject's box is often the whole picture, and
                // its top corner is where the biggest C patch's tag already sits.
                let b = place(s.box)
                tag("S\(i + 1)", at: CGRect(x: b.minX, y: b.minY, width: b.width, height: 24), in: ctx, colour: lime)
                lines.append("S\(i + 1): \(where_(s.box))")
            }
        }

        guard let image = ctx.makeImage(), let png = Renderer.png(image) else { return nil }
        return Made(png: png, text: lines.joined(separator: "\n"))
    }

    static func gray(_ v: CGFloat) -> CGColor { CGColor(red: v, green: v, blue: v, alpha: 1) }

    static func outline(_ rings: [[CGPoint]], in ctx: CGContext, colour: CGColor,
                        place: (CGPoint) -> CGPoint) {
        let path = CGMutablePath()
        for ring in rings where ring.count > 2 {
            path.addLines(between: ring.map(place))
            path.closeSubpath()
        }
        ctx.setStrokeColor(colour)
        ctx.setLineWidth(2)
        ctx.addPath(path)
        ctx.strokePath()
    }

    /// A label on a chip, at the top-left corner of a box, kept on the picture.
    static func tag(_ text: String, at box: CGRect, in ctx: CGContext, colour: CGColor) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 15, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let pad: CGFloat = 3
        let cw = bounds.width + pad * 2, ch = bounds.height + pad * 2
        let limitX = CGFloat(ctx.width) - cw, limitY = CGFloat(ctx.height) - ch
        let origin = CGPoint(x: min(max(0, box.minX), limitX), y: min(max(0, box.maxY - ch), limitY))
        ctx.setFillColor(colour)
        ctx.fill(CGRect(origin: origin, size: CGSize(width: cw, height: ch)))
        ctx.textPosition = CGPoint(x: origin.x + pad - bounds.minX, y: origin.y + pad - bounds.minY)
        CTLineDraw(line, ctx)
    }
}
