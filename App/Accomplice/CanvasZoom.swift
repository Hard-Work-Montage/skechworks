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
