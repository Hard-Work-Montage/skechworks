import AppKit

// The cursors for the pen and for point editing.
//
// A crosshair is the same picture whatever you are about to do — start a path, close
// one, drag a point you can see, or miss it entirely. Sketch answers all of that in the
// cursor: a nib while the pen is live, a badge on the nib saying whether the click adds
// or closes, and a plain arrow with a move glyph once the pointer is over a point.
// AppKit ships none of these, so they're drawn, the same way HandleCursors draws the
// resize and rotate arrows.
enum VectorCursors {

    /// What a pen click would do, drawn as a badge beside the nib.
    enum Badge: String { case add, close, plain }

    static func pen(_ badge: Badge = .add) -> NSCursor {
        cursor(key: "pen-" + badge.rawValue) { ctx in
            ctx.saveGState()
            // The nib is drawn pointing straight down and then swung round, so its tip
            // stays on the origin — which is the hot spot — whatever angle it ends at.
            ctx.rotate(by: -.pi / 4)
            let nib = CGMutablePath()
            nib.move(to: .zero)
            nib.addLine(to: CGPoint(x: -2.7, y: 4.8))
            nib.addLine(to: CGPoint(x: -2.7, y: 10.6))
            nib.addLine(to: CGPoint(x: 2.7, y: 10.6))
            nib.addLine(to: CGPoint(x: 2.7, y: 4.8))
            nib.closeSubpath()
            fill(ctx, nib)
            // The slot, punched back out in white, so the nib reads as a nib and not a
            // dart — at 14 points across that hole is most of the recognition.
            ctx.addEllipse(in: CGRect(x: -1.2, y: 5.9, width: 2.4, height: 2.4))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            let c = CGPoint(x: 4.0, y: 10.8)
            let mark = CGMutablePath()
            switch badge {
            case .add:
                let a: CGFloat = 2.4
                mark.move(to: CGPoint(x: c.x - a, y: c.y)); mark.addLine(to: CGPoint(x: c.x + a, y: c.y))
                mark.move(to: CGPoint(x: c.x, y: c.y - a)); mark.addLine(to: CGPoint(x: c.x, y: c.y + a))
                stroke(ctx, mark)
            case .close:
                // A wider ring drawn thinner than the plus, because at the plus's weight
                // a circle this small fills in solid and stops being a ring at all.
                mark.addEllipse(in: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5))
                stroke(ctx, mark, weight: 1.2, edge: 2.6)
            case .plain:
                break
            }
        }
    }

    /// Arrow with a move glyph: the pointer is on a point or a handle, so a drag moves
    /// what's already there rather than adding anything.
    static var movePoint: NSCursor {
        cursor(key: "move-point") { ctx in
            let arrow = CGMutablePath()
            arrow.move(to: .zero)
            arrow.addLine(to: CGPoint(x: 0, y: -12.2))
            arrow.addLine(to: CGPoint(x: 3.0, y: -9.3))
            arrow.addLine(to: CGPoint(x: 5.1, y: -13.4))
            arrow.addLine(to: CGPoint(x: 7.0, y: -12.4))
            arrow.addLine(to: CGPoint(x: 5.0, y: -8.4))
            arrow.addLine(to: CGPoint(x: 8.7, y: -8.1))
            arrow.closeSubpath()
            fill(ctx, arrow)

            // A solid glyph, not four strokes with arrowheads: at this size the white
            // halo under line art closes up the gaps and the badge silts into a blob.
            // The edge is thinner than usual for the same reason — the arms are close
            // enough together that a 3-point outline bridges the notches between them.
            fill(ctx, moveGlyph(at: CGPoint(x: 9.8, y: 7.0)), edge: 2)
        }
    }

    /// Scissors, tips at the hot spot, pointing up and to the left like the arrow.
    ///
    /// The blades are the recognisable part at this size, so they get the weight;
    /// the finger rings are drawn thin or they close up into two dots.
    static var scissors: NSCursor {
        cursor(key: "scissors") { ctx in
            ctx.saveGState()
            // Drawn pointing straight up, tips on the origin, then swung a quarter
            // of a right angle so the tips point the way a pointer does.
            ctx.rotate(by: .pi / 4)
            let blades = CGMutablePath()
            for side in [CGFloat(-1), 1] {
                // Tip, then the near and far edges down to the pivot.
                blades.move(to: CGPoint(x: side * 0.4, y: 0))
                blades.addLine(to: CGPoint(x: side * 2.4, y: -0.9))
                blades.addLine(to: CGPoint(x: side * -1.0, y: -7.6))
                blades.addLine(to: CGPoint(x: side * -2.0, y: -7.0))
                blades.closeSubpath()
            }
            fill(ctx, blades, edge: 2.4)
            let rings = CGMutablePath()
            for side in [CGFloat(-1), 1] {
                rings.move(to: CGPoint(x: side * -1.5, y: -7.3))
                rings.addLine(to: CGPoint(x: side * -2.9, y: -9.2))
                rings.addEllipse(in: CGRect(x: side * -3.6 - 2.4, y: -13.9, width: 4.8, height: 4.8))
            }
            stroke(ctx, rings, weight: 1.3, edge: 2.8)
            ctx.restoreGState()
        }
    }

    /// Four-way arrow, drawn as one outline.
    ///
    /// Each arm is the same run of points a quarter-turn on from the last, and an arm
    /// ends exactly where the next one starts, so the ring closes without any seams to
    /// show up as notches in the white edge.
    private static func moveGlyph(at c: CGPoint) -> CGPath {
        let arm: CGFloat = 5.2, head: CGFloat = 2.6, wing: CGFloat = 2.9, shaft: CGFloat = 0.9
        let path = CGMutablePath()
        for k in 0..<4 {
            let angle = CGFloat(k) * .pi / 2
            let cs = cos(angle), sn = sin(angle)
            func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: c.x + x * cs - y * sn, y: c.y + x * sn + y * cs)
            }
            if k == 0 { path.move(to: at(shaft, -shaft)) }
            path.addLine(to: at(arm - head, -shaft))
            path.addLine(to: at(arm - head, -wing))
            path.addLine(to: at(arm, 0))
            path.addLine(to: at(arm - head, wing))
            path.addLine(to: at(arm - head, shaft))
            path.addLine(to: at(shaft, shaft))
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Drawing

    nonisolated(unsafe) private static var cache: [String: NSCursor] = [:]

    /// The image is generously sized so a badge in one corner can't be clipped; only
    /// the hot spot matters for where the cursor appears to point.
    private static func cursor(key: String, _ body: (CGContext) -> Void) -> NSCursor {
        if let hit = cache[key] { return hit }
        // Drawn once, eagerly, rather than through NSImage's drawing handler — that
        // handler is escaping and is re-run at unpredictable moments.
        let side: CGFloat = 34
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocusFlipped(false)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.translateBy(x: side / 2, y: side / 2)
            body(ctx)
        }
        image.unlockFocus()
        let made = NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
        cache[key] = made
        return made
    }

    /// Solid black inside a white edge: the standard macOS treatment, and the only way
    /// a cursor stays legible over both a white artboard and dark artwork.
    private static func fill(_ ctx: CGContext, _ path: CGPath, edge: CGFloat = 3) {
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(edge)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
    }

    /// The same sandwich for line art — badges and the move glyph.
    private static func stroke(_ ctx: CGContext, _ path: CGPath,
                               weight: CGFloat = 1.5, edge: CGFloat = 3.2) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(edge)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(weight)
        ctx.strokePath()
    }
}
