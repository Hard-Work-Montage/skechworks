import AccompliceCore
import AppKit

// The little corner drawings in the corner-style menu.
//
// Drawn by Corners itself rather than hand-traced, so the menu can't end up showing a
// difference the shapes don't have — the whole point of the two entries is that one is
// squarer at the tangent and the other eases into it, and that's only worth a menu if
// you can see it.
enum CornerGlyph {

    static func image(_ style: CornerStyle) -> NSImage {
        if let hit = cache[style] { return hit }
        let side: CGFloat = 15, inset: CGFloat = 1.5
        let corner = CGMutablePath()
        corner.move(to: CGPoint(x: inset, y: inset))
        corner.addLine(to: CGPoint(x: inset, y: side - inset))
        corner.addLine(to: CGPoint(x: side - inset, y: side - inset))
        // A radius near the full length of the arms, which is where the two styles are
        // furthest apart. At a modest one they're the same picture.
        let rounded = Corners.round(corner.copy()!, radius: side - inset * 2, style: style)

        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocusFlipped(false)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(rounded)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.4)
            ctx.strokePath()
        }
        image.unlockFocus()
        // Template, so it picks up the menu's own colour and inverts with the theme.
        image.isTemplate = true
        cache[style] = image
        return image
    }

    nonisolated(unsafe) private static var cache: [CornerStyle: NSImage] = [:]
}
