import AppKit

// The cursors for resizing and rotating a selection.
//
// macOS ships resizeLeftRight and resizeUpDown and nothing else — no diagonals, no
// rotate — so a corner handle has no correct system cursor. These are drawn instead,
// which has the side benefit that the arrow can point along any angle: on a rotated
// layer the resize cursor follows the layer, the way Sketch's does, rather than
// pointing at a corner that isn't there any more.
enum HandleCursors {

    /// Double-headed straight arrow, pointing along `degrees` (clockwise from east in
    /// canvas space, which is y-down).
    static func resize(_ degrees: CGFloat) -> NSCursor {
        cursor(key: "r\(bucket(degrees))", rotatedBy: -degrees) { ctx in
            draw(ctx) { path in
                let r: CGFloat = 8
                path.move(to: CGPoint(x: -r, y: 0))
                path.addLine(to: CGPoint(x: r, y: 0))
                head(path, at: CGPoint(x: r, y: 0), pointing: 0)
                head(path, at: CGPoint(x: -r, y: 0), pointing: .pi)
            }
        }
    }

    /// Curved double-headed arrow, for the ring outside a corner.
    static func rotate(_ degrees: CGFloat) -> NSCursor {
        cursor(key: "t\(bucket(degrees))", rotatedBy: -degrees) { ctx in
            draw(ctx) { path in
                let r: CGFloat = 7
                // Just over half a turn, so both heads are clearly visible.
                path.addArc(center: .zero, radius: r, startAngle: -0.52 * .pi,
                            endAngle: 0.52 * .pi, clockwise: false)
                // Heads tangential to the arc at each end.
                let a1 = 0.52 * CGFloat.pi, a0 = -0.52 * CGFloat.pi
                head(path, at: CGPoint(x: cos(a1) * r, y: sin(a1) * r), pointing: a1 + .pi / 2)
                head(path, at: CGPoint(x: cos(a0) * r, y: sin(a0) * r), pointing: a0 - .pi / 2)
            }
        }
    }

    // MARK: - Drawing

    /// Angles are quantised so a slow mouse move doesn't rebuild an image per pixel.
    private static func bucket(_ d: CGFloat) -> Int {
        Int((d / 5).rounded()) * 5
    }

    nonisolated(unsafe) private static var cache: [String: NSCursor] = [:]

    private static func cursor(key: String, rotatedBy angle: CGFloat,
                               _ body: (CGContext) -> Void) -> NSCursor {
        if let hit = cache[key] { return hit }
        // Drawn once, eagerly, rather than through NSImage's drawing handler — that
        // handler is escaping and is re-run at unpredictable moments.
        let side: CGFloat = 28
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocusFlipped(false)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.translateBy(x: side / 2, y: side / 2)
            ctx.rotate(by: angle * .pi / 180)
            body(ctx)
        }
        image.unlockFocus()
        let made = NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
        cache[key] = made
        return made
    }

    /// White underneath, black on top: the standard macOS treatment, and the only way
    /// a cursor stays legible over both a white artboard and dark artwork.
    private static func draw(_ ctx: CGContext, _ shape: (CGMutablePath) -> Void) {
        let path = CGMutablePath()
        shape(path)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(3.5)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
    }

    private static func head(_ path: CGMutablePath, at tip: CGPoint, pointing angle: CGFloat) {
        let size: CGFloat = 4.2
        let spread = CGFloat.pi * 0.78
        for side in [angle + spread, angle - spread] {
            path.move(to: tip)
            path.addLine(to: CGPoint(x: tip.x + cos(side) * size, y: tip.y + sin(side) * size))
        }
    }
}
