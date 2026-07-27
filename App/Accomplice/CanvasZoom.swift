import AppKit

/// What the menu and toolbar ask the canvas to do about zoom.
///
/// Zoom lives on the store rather than in a view's `@State` so the View menu, the
/// toolbar and the canvas all drive one thing. It's a request, not a value: the
/// canvas owns the actual magnification, because only it knows the viewport.
enum ZoomIntent: Equatable {
    case fit
    case actualSize
    case zoomIn
    case zoomOut
    case toSelection
}

struct ZoomRequest: Equatable {
    /// Bumped per request so a repeat of the same intent still registers.
    var serial = 0
    var intent: ZoomIntent = .fit
}

/// An `NSScrollView` that zooms under ⌘-scroll.
///
/// `allowsMagnification` only buys the trackpad pinch gesture. A mouse wheel with
/// ⌘ held is the other half of how people zoom, and AppKit does nothing with it —
/// the event arrives as an ordinary scroll and the canvas just pans.
final class ZoomingScrollView: NSScrollView {

    /// Multiplier per ⌘+ / ⌘- step. Sketch-ish: coarse enough to get somewhere,
    /// fine enough to land on what you wanted.
    static let step: CGFloat = 1.25

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        // Zoom about the pointer, not the view centre — otherwise the thing you're
        // pointing at slides away exactly when you're trying to get closer to it.
        let anchor = documentView?.convert(event.locationInWindow, from: nil)
            ?? CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)

        // A trackpad reports many small precise deltas; a wheel reports a few large
        // notches. Scaling them the same way makes one of the two useless.
        let raw = event.scrollingDeltaY
        guard raw != 0 else { return }
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.06
        // exp() keeps it symmetric: scrolling up then down returns to where you were.
        let factor = exp(raw * sensitivity)
        setMagnification(magnification * factor, centeredAt: anchor)
    }

    /// Zooms by a factor about the middle of what's on screen.
    func zoom(by factor: CGFloat) {
        let centre = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        let anchor = documentView?.convert(centre, from: contentView) ?? centre
        setMagnification(magnification * factor, centeredAt: anchor)
    }

    /// Fits a rectangle in document coordinates, with a little air around it.
    func fit(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        magnify(toFit: rect.insetBy(dx: -rect.width * 0.03, dy: -rect.height * 0.03))
    }
}
