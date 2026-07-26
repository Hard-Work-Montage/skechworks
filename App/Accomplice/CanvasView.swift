import AccompliceCore
import AppKit
import SwiftUI

/// The canvas draws through `Renderer.draw(page:in:)` — the same call the exporter uses.
/// Screen and output can't disagree, which is the whole reason geometry lives in one place.
final class PageCanvas: NSView {

    var page: Page? { didSet { resize(); recompose(); needsDisplay = true } }
    var images: [String: Data] = [:] { didSet { needsDisplay = true } }
    var selectedID: String? { didSet { updateDragSet(); needsDisplay = true } }
    var onClick: ((CGPoint) -> Void)?
    var onDragBegin: ((String) -> Void)?
    var onDragEnd: ((CGSize) -> Void)?
    var onNudge: ((CGFloat, CGFloat) -> Void)?

    /// Live drag state. The model isn't touched until mouse-up; until then the canvas
    /// just offsets the already-composed drawables belonging to the dragged subtree.
    /// Recomposing per frame would cost ~0.6s of CGPath boolean work per tick.
    private var dragOffset: CGSize = .zero
    private var dragging = false
    private var dragAnchor: CGPoint = .zero
    private var dragSet: Set<String> = []

    private func updateDragSet() {
        guard let id = selectedID, let page,
              let l = page.layer(id) else { dragSet = []; return }
        dragSet = l.subtreeIDs
    }

    /// Sketch's canvas is y-down; matching it means no coordinate flipping anywhere.
    override var isFlipped: Bool { true }

    private var bounds1: CGRect = .zero

    /// Composed once per page, not once per frame. See Renderer.draw(drawables:in:).
    private var composed: [Drawable] = []
    private var composedFor: String?

    /// Artboard name labels, in page space. Sketch and Figma both put the name above
    /// the top-left corner and make it the handle for selecting the board itself —
    /// otherwise the only way to select an artboard is the layer list, since clicking
    /// inside it hits whatever art is on top.
    private struct ArtboardLabel {
        let id: String
        let name: String
        let frame: CGRect      // the artboard itself
        var hit: CGRect = .zero // the clickable label rect, filled in while drawing
    }
    private var artboards: [ArtboardLabel] = []

    private func collectArtboards(_ layers: [Layer], _ base: CGAffineTransform,
                                  _ out: inout [ArtboardLabel]) {
        for l in layers where l.isVisible {
            let t = Compose.transform(l).concatenating(base)
            if l.isArtboard {
                out.append(ArtboardLabel(id: l.id, name: l.name.isEmpty ? "Artboard" : l.name,
                                         frame: CGRect(origin: .zero, size: l.frame.size).applying(t)))
            }
            switch l.kind {
            case .group(let k), .shapeGroup(let k, _):
                collectArtboards(k, t, &out)
            default: break
            }
        }
    }

    private func recompose() {
        guard let page else { composed = []; composedFor = nil; return }
        guard composedFor != page.name || composed.isEmpty else { return }
        composed = Compose.flatten(page.layers)
        composedFor = page.name
        artboards = []
        collectArtboards(page.layers, .identity, &artboards)
    }

    /// The view's frame is the page content plus a margin.
    ///
    /// Artboard labels are drawn ABOVE their board, which for the topmost row means
    /// outside the content bounds. AppKit will happily draw there, but hit-testing
    /// stops at the view's frame — so those labels rendered fine and were unclickable,
    /// while labels lower down (sitting in the gap between rows) worked. The margin has
    /// to grow as you zoom out, because a label sized 11/magnification in page units
    /// gets larger the further out you go.
    private func resize() {
        guard let page else { bounds1 = .zero; return }
        let content = page.contentBounds()
        let margin = labelMargin
        bounds1 = content.insetBy(dx: -margin, dy: -margin)
        setFrameSize(NSSize(width: max(1, bounds1.width), height: max(1, bounds1.height)))
    }

    /// Deliberately NOT scale-dependent.
    ///
    /// Tying it to magnification created a feedback loop — smaller scale grew the
    /// margin, which grew the frame, which shrank the fit again. A margin proportional
    /// to the page has no such coupling, needs no notifications, and is plenty of room
    /// for a label at any zoom you'd actually click at.
    private var labelMargin: CGFloat {
        guard let page else { return 0 }
        let c = page.contentBounds()
        return max(40, max(c.width, c.height) * 0.05)
    }

    /// Where the actual artwork sits inside the padded frame. Fitting to THIS rather
    /// than the whole view is what keeps zoom-to-fit stable.
    var contentRectInView: CGRect {
        guard let page else { return bounds }
        let c = page.contentBounds()
        return CGRect(x: c.minX - bounds1.minX, y: c.minY - bounds1.minY,
                      width: c.width, height: c.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // No page background. A Sketch-style canvas is infinite and unpainted — only
        // artboards have a colour. Filling the view white made every page look like one
        // big artboard and hid where the real ones start and stop.
        guard let page else { return }
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: -bounds1.minX, y: -bounds1.minY)

        let r = Renderer(images: images)
        if dragging && dragOffset != .zero {
            let moved = composed.filter { dragSet.contains($0.layer.id) }
            let rest = composed.filter { !dragSet.contains($0.layer.id) }
            r.draw(drawables: rest, in: ctx)
            ctx.saveGState()
            ctx.translateBy(x: dragOffset.width, y: dragOffset.height)
            r.draw(drawables: moved, in: ctx)
            ctx.restoreGState()
        } else {
            r.draw(drawables: composed, in: ctx)
        }

        if let id = selectedID,
           var rect = frameOf(id, in: page.layers, base: .identity) {
            if dragging { rect = rect.offsetBy(dx: dragOffset.width, dy: dragOffset.height) }
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5 / max(0.01, currentScale))
            ctx.setLineDash(phase: 0, lengths: [4 / max(0.01, currentScale), 3 / max(0.01, currentScale)])
            ctx.stroke(rect.insetBy(dx: -1, dy: -1))
        }

        drawArtboardLabels()
        ctx.restoreGState()
    }

    /// Labels stay a constant size on screen, so they read the same at any zoom —
    /// which means sizing them in page units as 11 / magnification.
    private func drawArtboardLabels() {
        guard !artboards.isEmpty else { return }
        let scale = max(0.01, currentScale)
        let size = 11 / scale
        let gap = 5 / scale

        for i in artboards.indices {
            let ab = artboards[i]
            let selected = ab.id == selectedID
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: selected ? .semibold : .regular),
                .foregroundColor: selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
            ]
            let str = NSAttributedString(string: ab.name, attributes: attrs)
            let sz = str.size()
            var origin = CGPoint(x: ab.frame.minX, y: ab.frame.minY - sz.height - gap)
            if dragging && dragSet.contains(ab.id) {
                origin.x += dragOffset.width
                origin.y += dragOffset.height
            }
            str.draw(at: origin)
            // Generous hit area: the text is small on screen at low zoom.
            artboards[i].hit = CGRect(origin: origin, size: sz).insetBy(dx: -gap, dy: -gap / 2)
        }
    }

    private var currentScale: CGFloat {
        enclosingScrollView?.magnification ?? 1
    }

    /// Walks to the selected layer, accumulating transforms, and returns its canvas frame.
    private func frameOf(_ id: String, in layers: [Layer], base: CGAffineTransform) -> CGRect? {
        for l in layers {
            let t = Compose.transform(l).concatenating(base)
            if l.id == id {
                if let p = Compose.resolvedPath(l) { return p.transformed(by: t).boundingBoxOfPath }
                return CGRect(origin: .zero, size: l.frame.size).applying(t)
            }
            let kids: [Layer]
            switch l.kind {
            case .group(let k): kids = k
            case .shapeGroup(let k, _): kids = k
            default: kids = []
            }
            if let r = frameOf(id, in: kids, base: t) { return r }
        }
        return nil
    }

    /// Hit-tests against the cached composition rather than recomposing per click.
    /// Named distinctly because NSView already has `hitTest(_:) -> NSView?`.
    func layerHit(_ point: CGPoint) -> Layer? {
        // Labels win over content: they sit outside the board, and they're the only
        // way to grab the artboard rather than the art sitting on it.
        if let ab = artboards.first(where: { $0.hit.contains(point) }),
           let page, let l = page.layer(ab.id) {
            return l
        }
        for d in composed.reversed() {
            if let p = d.path, p.contains(point) { return d.layer }
            if d.path == nil {
                let r = CGRect(origin: .zero, size: d.layer.frame.size).applying(d.transform)
                if r.contains(point) { return d.layer }
            }
        }
        return nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let p = CGPoint(x: local.x + bounds1.minX, y: local.y + bounds1.minY)
        dragAnchor = p
        dragOffset = .zero

        // Clicking inside the current selection starts a drag; clicking elsewhere
        // re-selects first, so a single press can select and then move. Clicking bare
        // canvas clears the selection, which is also how you get out of one picked
        // from the layer list.
        let hit = layerHit(p)
        if hit?.id != selectedID { onClick?(p) }
        window?.makeFirstResponder(self)

        if let h = hit {
            dragging = true
            onDragBegin?(h.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let local = convert(event.locationInWindow, from: nil)
        let p = CGPoint(x: local.x + bounds1.minX, y: local.y + bounds1.minY)
        dragOffset = CGSize(width: p.x - dragAnchor.x, height: p.y - dragAnchor.y)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        let o = dragOffset
        dragOffset = .zero
        onDragEnd?(o)
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: onNudge?(-step, 0)   // left
        case 124: onNudge?(step, 0)    // right
        case 125: onNudge?(0, step)    // down (canvas is y-down)
        case 126: onNudge?(0, -step)   // up
        default: super.keyDown(with: event)
        }
    }
}

/// Keeps the page centred when it's smaller than the viewport. NSScrollView pins content
/// to the top-left otherwise, which reads as broken on a canvas.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return rect }
        let d = doc.frame
        if rect.width > d.width { rect.origin.x = (d.width - rect.width) / 2 }
        if rect.height > d.height { rect.origin.y = (d.height - rect.height) / 2 }
        return rect
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    @EnvironmentObject var store: DocumentStore
    let page: Page?
    let images: [String: Data]
    @Binding var selectedID: String?
    let zoomToken: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 40
        scroll.backgroundColor = .underPageBackgroundColor

        let canvas = PageCanvas()
        wire(canvas)
        scroll.documentView = canvas
        context.coordinator.canvas = canvas

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = context.coordinator.canvas else { return }
        let pageChanged = context.coordinator.lastPageName != page?.name
            || context.coordinator.lastZoomToken != zoomToken
        canvas.images = images
        canvas.page = page
        canvas.selectedID = selectedID
        wire(canvas)
        if pageChanged, let page {
            context.coordinator.lastPageName = page.name
            context.coordinator.lastZoomToken = zoomToken
            // Fit on arrival: these pages range from 180pt to 15,000pt wide, so a
            // fixed default zoom would be useless most of the time.
            let b = page.contentBounds()
            let vis = scroll.contentView.bounds.size
            if b.width > 0, b.height > 0, vis.width > 1, vis.height > 1 {
                // magnify(toFit:) both scales and scrolls, so the page lands centred
                // rather than jammed against the top-left.
                canvas.layoutSubtreeIfNeeded()
                // Fit, settle the scale-dependent label margin, fit again. The two
                // depend on each other, so one pass leaves the page slightly cropped.
                // A little past the content so the leftmost/topmost labels aren't
                // flush against the edge. Safe now that the margin is fixed.
                scroll.magnify(toFit: canvas.contentRectInView.insetBy(dx: -b.width * 0.03,
                                                                       dy: -b.height * 0.03))
            }
        }
    }

    private func wire(_ canvas: PageCanvas) {
        canvas.onClick = { [weak canvas] pt in
            selectedID = canvas?.layerHit(pt)?.id
        }
        canvas.onDragBegin = { id in store.beginDrag(id) }
        canvas.onDragEnd = { offset in store.endDrag(offset: offset) }
        canvas.onNudge = { dx, dy in store.nudge(dx: dx, dy: dy) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var canvas: PageCanvas?
        var lastPageName: String?
        var lastZoomToken: Int = -1
    }
}
