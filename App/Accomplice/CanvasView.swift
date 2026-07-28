import AccompliceCore
import AppKit
import SwiftUI

/// The canvas draws through `Renderer.draw(page:in:)` — the same call the exporter uses.
/// Screen and output can't disagree, which is the whole reason geometry lives in one place.
final class PageCanvas: NSView {

    var page: Page? { didSet { adoptPage(); needsDisplay = true } }

    /// Content revision. Changing it forces a recomposition — see DocumentStore.revision.
    var revision = 0 {
        didSet {
            guard revision != oldValue else { return }
            composedFor = nil
            recompose()
            growBounds()
            rebuildEditPath()
            needsDisplay = true
        }
    }
    var images: [String: Data] = [:] { didSet { needsDisplay = true } }
    var selected: Set<String> = [] {
        didSet {
            // Selecting something else leaves vector editing, the way it does in Sketch.
            if selected != oldValue, editingLayerID != nil, selected != [editingLayerID!] {
                editingLayerID = nil
            }
            updateDragSet(); rebuildEditPath(); needsDisplay = true
        }
    }

    /// The group you have double-clicked into.
    ///
    /// Sketch calls this entering a group: while you're inside one, clicks select its
    /// members rather than re-selecting the group as a whole. Clicking outside it, or
    /// pressing escape, comes back out.
    private var enteredGroup: String? { didSet { needsDisplay = true } }

    /// The layer being point-edited, entered by double-clicking a shape.
    ///
    /// Points used to appear as soon as a path was selected, which left no room for a
    /// single click to mean "add a point" — it already meant "drag the shape". Sketch
    /// separates the two with a mode, and so does this.
    private var editingLayerID: String? { didSet { rebuildEditPath(); needsDisplay = true } }
    /// The canvas resolves what a click means (group vs the layer inside it) before
    /// telling anyone, so selection policy lives in one place rather than in the store.
    var onSelect: ((String?, Bool) -> Void)?        // layer id, extend (shift held)
    var onMarquee: ((CGRect, Bool) -> Void)?         // rect, extend
    var onDragBegin: ((String) -> Void)?
    var onResizeBegin: (() -> Void)?
    var onResizeEnd: ((CGSize, CGPoint) -> Void)?
    var onDrawPath: ((VectorPath) -> Void)?
    var onEditPath: ((VectorPath, String, String) -> Void)?
    /// Which point is under the cursor's attention, for the Point Type control.
    var onPointSelected: ((Int?, CurveMode?) -> Void)?

    var tool: DocumentStore.Tool = .select {
        didSet {
            guard tool != oldValue else { return }
            if tool != .pen { finishPen(close: false) }
            rebuildEditPath()
            needsDisplay = true
        }
    }

    // MARK: - Pen / point editing state

    /// Points placed so far by the pen, in page space. Corner-first: a click drops an
    /// anchor with no handles, and you curve it afterwards with the bend tool. That
    /// matches how Adam draws — click, click, click, then adjust.
    private var penPoints: [VectorPoint] = []
    private var penCursor: CGPoint?
    /// Where a double-click would drop a new point, while hovering an edited path.
    private var insertPreview: CGPoint?
    /// The segment and parameter that preview refers to, so the keyboard can use it.
    private var insertTarget: (segment: Int, t: CGFloat)?
    /// Last known pointer position in page space, for the keyboard shortcuts.
    private var hoverPoint: CGPoint?

    /// The selected path, exploded into editable points (page space).
    private var editPath: VectorPath?
    private var editLayerID: String?
    private var editTransform: CGAffineTransform = .identity
    private var draggingPoint: Int?
    private var draggingHandle: (index: Int, out: Bool)?
    private var bendingSegment: Int?
    /// A press on a segment, not yet decided. Moving turns it into a bend; releasing
    /// without moving adds a point there.
    private var pendingSegment: (index: Int, at: CGPoint, centred: Bool)?
    private var lastTouchedPoint: Int? {
        didSet {
            guard lastTouchedPoint != oldValue else { return }
            let mode = lastTouchedPoint.flatMap { editPath?.points[safe: $0]?.mode }
            onPointSelected?(lastTouchedPoint, mode)
        }
    }

    private var pointRadius: CGFloat { 4 / max(0.01, currentScale) }
    private var grabRadius: CGFloat { 7 / max(0.01, currentScale) }

    /// Rebuilds the editable point list when the selection changes.
    ///
    /// Points live in page space so hit-testing and dragging need no per-event
    /// transform maths; they're converted back into the layer's own space on commit.
    private func rebuildEditPath() {
        editPath = nil; editLayerID = nil; editTransform = .identity
        // The bend tool is a point-editing tool: it implies the mode.
        let target = editingLayerID
        guard tool != .pen, let page, selected.count == 1, let id = target,
              selected.contains(id),
              let l = page.layer(id), case .path(let cg, _) = l.kind else { return }
        guard let t = transformOf(id, in: page.layers, base: .identity) else { return }
        editTransform = t
        editLayerID = id
        editPath = VectorPath(cgPath: cg.transformed(by: t), modes: l.curveModes)
    }

    private func transformOf(_ id: String, in layers: [Layer], base: CGAffineTransform) -> CGAffineTransform? {
        for l in layers {
            let t = Compose.transform(l).concatenating(base)
            if l.id == id { return t }
            switch l.kind {
            case .group(let k), .shapeGroup(let k, _):
                if let hit = transformOf(id, in: k, base: t) { return hit }
            default: continue
            }
        }
        return nil
    }

    private func commitEdit(_ name: String) {
        guard let vp = editPath, let id = editLayerID else { return }
        // Back into the layer's own space, undoing the transform we applied to edit in.
        var local = VectorPath(cgPath: vp.cgPath().transformed(by: editTransform.inverted()))
        // Carry the chosen types across; the round trip through CGPath drops them.
        if local.points.count == vp.points.count {
            for i in local.points.indices { local.points[i].mode = vp.points[i].mode }
        }
        onEditPath?(local, id, name)
    }

    func finishPen(close: Bool) {
        guard penPoints.count >= 2 else { penPoints = []; penCursor = nil; return }
        var vp = VectorPath(points: penPoints, closed: close)
        if close, vp.points.count > 2 { vp.closed = true }
        penPoints = []
        penCursor = nil
        onDrawPath?(vp)
        needsDisplay = true
    }
    var onDragEnd: ((CGSize) -> Void)?
    var onNudge: ((CGFloat, CGFloat) -> Void)?
    var onDelete: (() -> Void)?
    var onZoom: ((ZoomIntent) -> Void)?

    /// Live drag state. The model isn't touched until mouse-up; until then the canvas
    /// just offsets the already-composed drawables belonging to the dragged subtree.
    /// Recomposing per frame would cost ~0.6s of CGPath boolean work per tick.
    private var dragOffset: CGSize = .zero
    private var dragging = false
    private var marqueeing = false

    /// Which resize handle is being dragged, if any.
    ///
    /// Handles are drawn at a constant SCREEN size, so their hit radius has to be
    /// converted back into page units — otherwise they'd be unusably small zoomed out
    /// and enormous zoomed in.
    enum Handle: CaseIterable { case nw, n, ne, e, se, s, sw, w }
    private var activeHandle: Handle?
    private var resizeScale = CGSize(width: 1, height: 1)
    private var resizeAnchor: CGPoint = .zero

    /// A rotate drag in flight: where it turns about, and the pointer angle it began at.
    private var rotating: (centre: CGPoint, startAngle: CGFloat)?
    private var rotationDelta: CGFloat = 0
    var onRotateBegin: (() -> Void)?
    var onRotateEnd: ((CGFloat, CGPoint) -> Void)?

    /// Union of the selected layers' boxes, in page space.
    var selectionBounds: CGRect? {
        guard let page, !selected.isEmpty else { return nil }
        var r = CGRect.null
        for id in selected {
            if let f = frameOf(id, in: page.layers, base: .identity) { r = r.union(f) }
        }
        return r.isNull ? nil : r
    }

    /// The selection in view coordinates, for zoom-to-selection. Empty when nothing
    /// is selected, which the caller treats as "fit the page instead".
    var selectionRectInView: CGRect {
        guard let r = selectionBounds else { return .zero }
        return CGRect(x: r.minX - bounds1.minX, y: r.minY - bounds1.minY,
                      width: r.width, height: r.height)
    }

    private func handlePoint(_ h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .nw: return CGPoint(x: r.minX, y: r.minY)
        case .n:  return CGPoint(x: r.midX, y: r.minY)
        case .ne: return CGPoint(x: r.maxX, y: r.minY)
        case .e:  return CGPoint(x: r.maxX, y: r.midY)
        case .se: return CGPoint(x: r.maxX, y: r.maxY)
        case .s:  return CGPoint(x: r.midX, y: r.maxY)
        case .sw: return CGPoint(x: r.minX, y: r.maxY)
        case .w:  return CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// The point that stays put while a given handle is dragged.
    private func anchorPoint(_ h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .nw: return CGPoint(x: r.maxX, y: r.maxY)
        case .n:  return CGPoint(x: r.minX, y: r.maxY)
        case .ne: return CGPoint(x: r.minX, y: r.maxY)
        case .e:  return CGPoint(x: r.minX, y: r.minY)
        case .se: return CGPoint(x: r.minX, y: r.minY)
        case .s:  return CGPoint(x: r.minX, y: r.minY)
        case .sw: return CGPoint(x: r.maxX, y: r.minY)
        case .w:  return CGPoint(x: r.maxX, y: r.minY)
        }
    }

    /// Corners have a second, larger hit zone just outside them: inside turns into a
    /// resize, outside into a rotate. It's how Figma does it, and it needs no extra
    /// controls cluttering a selection that's often only a few pixels across.
    private func rotateCornerUnder(_ p: CGPoint) -> Handle? {
        guard let r = selectionBounds, editPath == nil, tool == .select else { return nil }
        let grab = 7 / max(0.01, currentScale)
        for h in [Handle.nw, .ne, .se, .sw] {
            let c = handlePoint(h, in: r)
            let d = hypot(p.x - c.x, p.y - c.y)
            if d > grab, d <= grab * 3 { return h }
        }
        return nil
    }

    /// Which way the arrow points for a handle, clockwise from east in canvas space.
    ///
    /// Edges point along their own normal, corners along their diagonal. A rotated
    /// layer takes its rotation with it, so the cursor lines up with the edge you are
    /// actually about to drag rather than with the screen.
    private func handleAngle(_ h: Handle) -> CGFloat {
        // A double-headed arrow is symmetric, so opposite handles share an angle.
        let base: CGFloat
        switch h {
        case .e, .w:   base = 0
        case .n, .s:   base = 90
        case .ne, .sw: base = -45
        case .nw, .se: base = 45
        }
        // Only for a single layer: a mixed selection has no one angle to follow.
        if selected.count == 1, let id = selected.first, let l = page?.layer(id) {
            return base - l.rotation
        }
        return base
    }

    /// Which way the rotate cursor faces at a corner: outward, away from the shape.
    ///
    /// The curved arrow is NOT symmetric — the arc opens to one side — so unlike the
    /// resize arrow it can't share an angle between opposite corners. Reusing the
    /// ±45 pair had the two left-hand corners curling the wrong way.
    private func rotateAngle(_ h: Handle) -> CGFloat {
        let outward: CGFloat
        switch h {
        case .se: outward = 45          // down-right
        case .sw: outward = 135         // down-left
        case .nw: outward = 225         // up-left
        case .ne: outward = 315         // up-right
        default:  outward = 0
        }
        if selected.count == 1, let id = selected.first, let l = page?.layer(id) {
            return outward - l.rotation
        }
        return outward
    }

    /// Picks the cursor for wherever the pointer is.
    private func updateCursor(at p: CGPoint) {
        if editPath != nil {
            // Point editing has its own affordance.
            NSCursor.crosshair.set()
            return
        }
        if let corner = rotateCornerUnder(p) {
            HandleCursors.rotate(rotateAngle(corner)).set()
            return
        }
        if let h = handleUnder(p) {
            HandleCursors.resize(handleAngle(h)).set()
            return
        }
        NSCursor.arrow.set()
    }

    private func handleUnder(_ p: CGPoint) -> Handle? {
        guard let r = selectionBounds else { return nil }
        let grab = 7 / max(0.01, currentScale)
        for h in Handle.allCases {
            let c = handlePoint(h, in: r)
            if abs(p.x - c.x) <= grab && abs(p.y - c.y) <= grab { return h }
        }
        return nil
    }
    private var dragAnchor: CGPoint = .zero
    private var dragSet: Set<String> = []

    private func updateDragSet() {
        guard let page else { dragSet = []; return }
        dragSet = selected.reduce(into: Set<String>()) { acc, id in
            if let l = page.layer(id) { acc.formUnion(l.subtreeIDs) }
        }
    }

    /// Rubber-band rect while marquee-selecting, in page space.
    private var marquee: CGRect?

    /// Sketch's canvas is y-down; matching it means no coordinate flipping anywhere.
    override var isFlipped: Bool { true }

    private var bounds1: CGRect = .zero

    /// Composed once per page, not once per frame. See Renderer.draw(drawables:in:).
    private var composed: [Drawable] = []
    private var composedFor: String?

    /// The move or resize being previewed, as a page-space transform.
    private var liveGesture: CGAffineTransform? {
        if let rot = rotating, rotationDelta != 0 {
            return CGAffineTransform(translationX: rot.centre.x, y: rot.centre.y)
                .rotated(by: -rotationDelta * .pi / 180)
                .translatedBy(x: -rot.centre.x, y: -rot.centre.y)
        }
        if dragging, dragOffset != .zero {
            return CGAffineTransform(translationX: dragOffset.width, y: dragOffset.height)
        }
        if activeHandle != nil, resizeScale != CGSize(width: 1, height: 1) {
            return CGAffineTransform(translationX: resizeAnchor.x, y: resizeAnchor.y)
                .scaledBy(x: resizeScale.width, y: resizeScale.height)
                .translatedBy(x: -resizeAnchor.x, y: -resizeAnchor.y)
        }
        return nil
    }

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
        // A gesture in progress recomposes every frame. It has to: the alternative —
        // shifting already-composed drawables — moves their clips too, so a mask the
        // gesture isn't touching travels with the art and springs back on release.
        let gesture = liveGesture
        let key = page.name + (gesture == nil ? "" : "|live")
        if gesture != nil {
            composed = Compose.flatten(page.layers, adjusting: selected, live: gesture!)
            composedFor = key
            return
        }
        guard composedFor != key || composed.isEmpty else { return }
        // composedFor is cleared by `revision` when contents change, which is what
        // makes an edit rebuild this rather than redrawing stale geometry.
        composed = Compose.flatten(page.layers)
        composedFor = key
        artboards = []
        collectArtboards(page.layers, .identity, &artboards)
    }

    /// Identity of the page whose bounds we're currently using. A token rather than a
    /// name, because names collide across documents.
    private var boundsToken: Int = -1
    var pageToken: Int = 0 { didSet { if pageToken != oldValue { adoptPage(); needsDisplay = true } } }

    /// How far past the artwork you can scroll.
    ///
    /// Sketch and Figma both give you a canvas that doesn't end — you push the page
    /// off to one side and work in the space beside it. With a margin sized to the
    /// labels there was nowhere to go: the document view barely exceeded the content,
    /// so scrolling stopped at the artwork and anything smaller than the window was
    /// pinned to the middle.
    ///
    /// Not literally infinite. A document a few times the size of the artwork, with a
    /// floor for small pages, is indistinguishable from infinite in use and keeps the
    /// coordinates ordinary.
    private var canvasMargin: CGFloat {
        CanvasExtent.margin(for: page?.contentBounds().size ?? .zero)
    }

    /// The view's frame is the page content plus a margin.
    ///
    /// Artboard labels are drawn ABOVE their board, which for the topmost row means
    /// outside the content bounds — and hit-testing stops at the view's frame, so
    /// without the margin those labels render but can't be clicked.
    ///
    /// Recomputed only when the PAGE changes, never merely because content moved. The
    /// canvas is infinite: dragging artwork must not shift the coordinate origin under
    /// everything else, or the whole page appears to jump and re-centre. It only ever
    /// grows, and growing compensates the scroll so nothing visibly moves.
    private func adoptPage() {
        guard let page else { bounds1 = .zero; boundsToken = -1; return }
        if boundsToken != pageToken {
            boundsToken = pageToken
            let margin = canvasMargin
            bounds1 = page.contentBounds().insetBy(dx: -margin, dy: -margin)
            setFrameSize(NSSize(width: max(1, bounds1.width), height: max(1, bounds1.height)))
            composedFor = nil
        }
        recompose()
    }

    private func growBounds() {
        guard let page else { return }
        let margin = labelMargin
        let needed = page.contentBounds().insetBy(dx: -margin, dy: -margin)
        let union = bounds1.union(needed)
        guard union != bounds1 else { return }
        // Growing at the top or left moves the origin; scroll by the same amount so
        // the view stays put instead of lurching.
        let dx = bounds1.minX - union.minX
        let dy = bounds1.minY - union.minY
        bounds1 = union
        setFrameSize(NSSize(width: max(1, bounds1.width), height: max(1, bounds1.height)))
        if dx != 0 || dy != 0, let clip = enclosingScrollView?.contentView {
            let o = clip.bounds.origin
            clip.scroll(to: NSPoint(x: o.x + dx, y: o.y + dy))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
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

        Renderer(images: images).draw(drawables: composed, in: ctx)

        let sc = max(0.01, currentScale)
        for id in selected {
            guard let raw = frameOf(id, in: page.layers, base: .identity) else { continue }
            let rect = previewed(raw)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5 / sc)
            ctx.setLineDash(phase: 0, lengths: [4 / sc, 3 / sc])
            ctx.stroke(rect.insetBy(dx: -1, dy: -1))
        }
        ctx.setLineDash(phase: 0, lengths: [])

        if let m = marquee {
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
            ctx.fill(m)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1 / sc)
            ctx.setLineDash(phase: 0, lengths: [4 / sc, 3 / sc])
            ctx.stroke(m)
            ctx.setLineDash(phase: 0, lengths: [])
        }

        drawHandles(ctx)
        drawPointOverlay(ctx)
        drawPenPreview(ctx)
        drawArtboardLabels()
        ctx.restoreGState()
    }

    /// Anchors and handles for the path being edited.
    private func drawPointOverlay(_ ctx: CGContext) {
        guard let vp = editPath, tool != .pen else { return }
        let sc = max(0.01, currentScale)

        // The path itself, so the shape reads while you're moving points around.
        ctx.addPath(vp.cgPath())
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1 / sc)
        ctx.strokePath()

        for (i, p) in vp.points.enumerated() {
            // Handles first, so anchors sit on top of their own lines.
            for (has, h) in [(p.hasCurveFrom, p.curveFrom), (p.hasCurveTo, p.curveTo)] where has {
                ctx.move(to: p.point); ctx.addLine(to: h)
                ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor)
                ctx.setLineWidth(1 / sc)
                ctx.strokePath()
                let hr = pointRadius * 0.8
                ctx.addEllipse(in: CGRect(x: h.x - hr, y: h.y - hr, width: hr * 2, height: hr * 2))
                ctx.setFillColor(NSColor.controlAccentColor.cgColor)
                ctx.fillPath()
            }
            let r = pointRadius
            let box = CGRect(x: p.point.x - r, y: p.point.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.4 / sc)
            // Corners draw square, smooth points round — the shape tells you the mode.
            if p.isCorner { ctx.fill(box); ctx.stroke(box) }
            else { ctx.fillEllipse(in: box); ctx.strokeEllipse(in: box) }
            _ = i
        }

        // A ghost point with a cross through it: where a double-click would land.
        if let g = insertPreview {
            let r = pointRadius
            let box = CGRect(x: g.x - r, y: g.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.4 / sc)
            ctx.fillEllipse(in: box)
            ctx.strokeEllipse(in: box)
            let arm = r * 0.55
            ctx.move(to: CGPoint(x: g.x - arm, y: g.y)); ctx.addLine(to: CGPoint(x: g.x + arm, y: g.y))
            ctx.move(to: CGPoint(x: g.x, y: g.y - arm)); ctx.addLine(to: CGPoint(x: g.x, y: g.y + arm))
            ctx.strokePath()
        }
    }

    private func drawPenPreview(_ ctx: CGContext) {
        guard tool == .pen, !penPoints.isEmpty else { return }
        let sc = max(0.01, currentScale)
        var preview = VectorPath(points: penPoints, closed: false)
        if let c = penCursor { preview.points.append(VectorPoint(c)) }
        ctx.addPath(preview.cgPath())
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.2 / sc)
        ctx.strokePath()

        for (i, p) in penPoints.enumerated() {
            let r = pointRadius
            let box = CGRect(x: p.point.x - r, y: p.point.y - r, width: r * 2, height: r * 2)
            // The first point is the one you click to close, so make it obvious.
            ctx.setFillColor(i == 0 ? NSColor.controlAccentColor.cgColor : NSColor.white.cgColor)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.4 / sc)
            ctx.fill(box); ctx.stroke(box)
        }
    }

    /// Applies whatever gesture is in flight to a rect.
    ///
    /// The selection frame and the handles both need this, and previously only the
    /// handles knew about resizing — so during a drag the dashed box sat at the old
    /// size while the handles moved, then snapped on release.
    private func previewed(_ r: CGRect) -> CGRect {
        if dragging, dragOffset != .zero {
            return r.offsetBy(dx: dragOffset.width, dy: dragOffset.height)
        }
        if activeHandle != nil {
            let a = resizeAnchor
            return CGRect(x: a.x + (r.minX - a.x) * resizeScale.width,
                          y: a.y + (r.minY - a.y) * resizeScale.height,
                          width: r.width * resizeScale.width,
                          height: r.height * resizeScale.height).standardized
        }
        return r
    }

    private func drawHandles(_ ctx: CGContext) {
        guard editPath == nil, tool == .select else { return }
        // Handles stay put through a resize (you're holding one) but hide during a
        // move or a marquee, where they'd just be noise.
        guard let bounds = selectionBounds, !marqueeing,
              !(dragging && dragOffset != .zero) else { return }
        let r = previewed(bounds)
        let sc = max(0.01, currentScale)
        let size = 7 / sc
        for h in Handle.allCases {
            let c = handlePoint(h, in: r)
            let box = CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(box)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.2 / sc)
            ctx.stroke(box)
        }
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
            let selected = self.selected.contains(ab.id)
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
    /// What clicking on `leaf` selects.
    ///
    /// A group is one object: clicking any part of it selects the whole thing, not the
    /// photo inside. So the click walks up to the outermost container that isn't an
    /// artboard — artboards hold everything on the page and selecting one from a click
    /// inside would make the rest of the canvas unreachable.
    ///
    /// `drill` (⇧⌘) takes the layer actually under the pointer instead, however deep.
    func selectionTarget(_ leaf: Layer, drill: Bool) -> Layer {
        guard !drill, let page else { return leaf }
        let chain = page.ancestors(of: leaf.id)

        // Inside a group: pick the member of THAT group, not the outermost container.
        if let entered = enteredGroup, chain.contains(entered) {
            if let i = chain.firstIndex(of: entered) {
                let below = i + 1 < chain.count ? chain[i + 1] : leaf.id
                return page.layer(below) ?? leaf
            }
        }
        var target = leaf
        for id in chain {
            guard let a = page.layer(id) else { continue }
            if a.isArtboard { continue }        // never swallow the click
            target = a
            break                                // outermost wins
        }
        return target
    }

    /// One step further into whatever is under the pointer, from what's selected now.
    /// Double-clicking a group enters it; double-clicking again goes deeper.
    private func deeper(than current: Set<String>, towards leaf: Layer) -> Layer? {
        guard let page else { return nil }
        let chain = page.ancestors(of: leaf.id) + [leaf.id]
        guard let here = chain.lastIndex(where: { current.contains($0) }) else { return nil }
        guard here + 1 < chain.count else { return nil }
        return page.layer(chain[here + 1])
    }

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let p = CGPoint(x: local.x + bounds1.minX, y: local.y + bounds1.minY)
        dragAnchor = p
        dragOffset = .zero
        marquee = nil
        let extend = event.modifierFlags.contains(.shift)

        // Clicking inside the current selection starts a drag; clicking elsewhere
        // re-selects first, so a single press can select and then move. Clicking bare
        // canvas starts a marquee instead.
        window?.makeFirstResponder(self)

        // --- Pen: click to drop a corner point ---
        if tool == .pen {
            if let first = penPoints.first, penPoints.count >= 2,
               hypot(p.x - first.point.x, p.y - first.point.y) <= grabRadius {
                finishPen(close: true)          // clicking the first point closes it
            } else {
                penPoints.append(VectorPoint(p))
                needsDisplay = true
            }
            return
        }

        // --- Double-click the path to add a point ---
        //
        // Not a single click: in point-editing a single click already selects and
        // drags points and starts a marquee, so it has nowhere free to go.
        // --- Double-click a shape to edit its points ---
        if event.clickCount >= 2, editPath == nil, tool == .select, let leaf = layerHit(p) {
            // Already on the layer itself and it's a path: the next step in is its
            // points.
            if selected == [leaf.id], case .path = leaf.kind {
                editingLayerID = leaf.id
                return
            }
            // Otherwise step into the group under the pointer and take whatever is
            // frontmost inside it — one double-click on a masked group lands on the
            // photo, rather than needing a second to get past the group itself.
            let current = selectionTarget(leaf, drill: false)
            if let group = page?.layer(current.id), group.isContainer {
                enteredGroup = current.id
                onSelect?(selectionTarget(leaf, drill: false).id, false)
            } else {
                onSelect?(leaf.id, false)
            }
            return
        }

        // --- Drag a segment to bend it ---
        //
        // Was its own tool. It isn't one: it's a gesture on a path you're already
        // editing, and making it a mode meant leaving the mode to do anything else.
        // A press that turns into a drag bends; a press that doesn't adds a point,
        // decided in mouseUp.
        if editPath != nil, !isOnPointOrHandle(p),
           let vp = editPath, let hit = vp.closestSegment(to: p, within: grabRadius * 2) {
            pendingSegment = (hit.index, p, extend)
            return
        }

        // --- In point editing, a single click on the path adds a point ---
        //
        // One click, like Sketch. It's only unambiguous because this is a mode you
        // entered deliberately: existing points and handles are tested first, and a
        // click nowhere near the path leaves the mode rather than adding anything.
        if editPath != nil, !isOnPointOrHandle(p) {
            if let t = insertionTarget(at: p, centred: extend) {
                insertTarget = t
                if insertPointAtPreview() { return }
            }
            if tool == .select {
                // Missed the path entirely: step out and let the click select normally.
                editingLayerID = nil
            }
        }

        // --- Bend: grab the nearest segment of the edited path ---


        // --- Point editing on the selected path ---
        if let vp = editPath {
            for (i, pt) in vp.points.enumerated() {
                if pt.hasCurveFrom, hypot(p.x - pt.curveFrom.x, p.y - pt.curveFrom.y) <= grabRadius {
                    draggingHandle = (i, true); return
                }
                if pt.hasCurveTo, hypot(p.x - pt.curveTo.x, p.y - pt.curveTo.y) <= grabRadius {
                    draggingHandle = (i, false); return
                }
            }
            for (i, pt) in vp.points.enumerated()
            where hypot(p.x - pt.point.x, p.y - pt.point.y) <= grabRadius {
                draggingPoint = i
                lastTouchedPoint = i
                return
            }
        }

        if rotateCornerUnder(p) != nil, let r = selectionBounds {
            let centre = CGPoint(x: r.midX, y: r.midY)
            rotating = (centre, atan2(p.y - centre.y, p.x - centre.x))
            rotationDelta = 0
            onRotateBegin?()
            return
        }

        // Handles win over everything: they sit on the selection's edge, which is
        // usually on top of the art you'd otherwise hit.
        if let handle = handleUnder(p), let r = selectionBounds {
            activeHandle = handle
            resizeAnchor = anchorPoint(handle, in: r)
            resizeScale = CGSize(width: 1, height: 1)
            onResizeBegin?()
            return
        }

        guard let leaf = layerHit(p) else {
            if !extend { onSelect?(nil, false) }   // clears the selection
            enteredGroup = nil
            marqueeing = true
            return
        }
        // A click on something outside the group you're in takes you back out.
        if let entered = enteredGroup, let page,
           !page.isInside(leaf.id, entered) {
            enteredGroup = nil
        }
        // ⇧⌘ drills past the group to the layer actually under the pointer.
        let drill = event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift)
        let h = selectionTarget(leaf, drill: drill)
        if !selected.contains(h.id) || extend { onSelect?(h.id, extend && !drill) }
        if !extend || drill {
            dragging = true
            onDragBegin?(h.id)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let p = CGPoint(x: local.x + bounds1.minX, y: local.y + bounds1.minY)

        // Nothing is drawn out there, so the cursor is the only clue the rotate zone
        // exists. Without it you'd only find it by accident.
        if editPath == nil { updateCursor(at: p) }

        if tool == .pen, !penPoints.isEmpty {
            penCursor = p
            needsDisplay = true
            return
        }

        // Show where a point would land while editing one. Double-click is not a
        // gesture anyone guesses at, so the path has to offer it.
        hoverPoint = p
        refreshInsertPreview()
    }

    /// True when the pointer is over an existing anchor or handle, which always wins:
    /// dragging a point you can see must never turn into adding one on top of it.
    private func isOnPointOrHandle(_ p: CGPoint) -> Bool {
        guard let vp = editPath else { return false }
        return vp.points.contains { pt in
            hypot(p.x - pt.point.x, p.y - pt.point.y) <= grabRadius
                || (pt.hasCurveFrom && hypot(p.x - pt.curveFrom.x, p.y - pt.curveFrom.y) <= grabRadius)
                || (pt.hasCurveTo && hypot(p.x - pt.curveTo.x, p.y - pt.curveTo.y) <= grabRadius)
        }
    }

    /// Where an inserted point would land for a pointer at `p`.
    ///
    /// Shift snaps to the middle of the segment. That's the parametric midpoint, which
    /// sits *on* the curve — halfway between the neighbouring points along the path,
    /// and on a straight segment exactly their geometric midpoint.
    private func insertionTarget(at p: CGPoint, centred: Bool) -> (segment: Int, t: CGFloat)? {
        guard let vp = editPath, !isOnPointOrHandle(p),
              let hit = vp.closestSegment(to: p, within: grabRadius * 2) else { return nil }
        return (hit.index, centred ? 0.5 : hit.t)
    }

    private func refreshInsertPreview() {
        guard let p = hoverPoint, let vp = editPath else {
            if insertPreview != nil { insertPreview = nil; insertTarget = nil; needsDisplay = true }
            return
        }
        let centred = NSEvent.modifierFlags.contains(.shift)
        let target = insertionTarget(at: p, centred: centred)
        let spot = target.flatMap { t -> CGPoint? in
            guard let (a, b) = vp.segment(t.segment) else { return nil }
            return VectorPath.evaluate(a, b, t.t)
        }
        if spot != insertPreview {
            insertPreview = spot
            insertTarget = target
            needsDisplay = true
        }
        // Sketch shows a pen with a plus here. The cursor is what tells you a click
        // will add rather than select, before you find out by doing it.
        if spot != nil { NSCursor.crosshair.set() }
    }

    /// Applies a point-type change from the inspector.
    func applyPointMode(_ m: CurveMode) {
        guard let vp = editPath, let i = lastTouchedPoint, vp.points.indices.contains(i) else { return }
        let prev = i > 0 ? vp.points[i - 1].point : (vp.closed ? vp.points.last?.point : nil)
        let next = i < vp.points.count - 1 ? vp.points[i + 1].point : (vp.closed ? vp.points.first?.point : nil)
        editPath?.points[i].convert(to: m, previous: prev, next: next)
        commitEdit("Change Point Type")
        onPointSelected?(i, m)
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if editPath == nil { NSCursor.arrow.set() }
    }

    /// Shift can be pressed without the pointer moving, and the preview has to follow.
    override func flagsChanged(with event: NSEvent) {
        refreshInsertPreview()
        super.flagsChanged(with: event)
    }

    /// Adds a point where the preview shows, for the keyboard path.
    @discardableResult
    private func insertPointAtPreview() -> Bool {
        guard let t = insertTarget, let made = editPath?.insertPoint(onSegment: t.segment, at: t.t)
        else { return false }
        lastTouchedPoint = made
        commitEdit("Add Point")
        refreshInsertPreview()
        needsDisplay = true
        return true
    }

    /// Removes the point under the pointer, or the last one touched.
    @discardableResult
    private func removePointUnderCursor() -> Bool {
        guard let vp = editPath, vp.points.count > 2 else { return false }
        var index = hoverPoint.flatMap { p in
            vp.points.firstIndex { hypot(p.x - $0.point.x, p.y - $0.point.y) <= grabRadius }
        }
        if index == nil { index = lastTouchedPoint }
        guard let i = index, vp.points.indices.contains(i) else { return false }
        editPath?.removePoint(i)
        lastTouchedPoint = nil
        commitEdit("Delete Point")
        refreshInsertPreview()
        needsDisplay = true
        return true
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        refreshInsertPreview()
    }

    override func mouseDragged(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let p = CGPoint(x: local.x + bounds1.minX, y: local.y + bounds1.minY)

        if let i = draggingPoint {
            editPath?.points[i].move(to: p); needsDisplay = true; return
        }
        if let h = draggingHandle {
            editPath?.points[h.index].setHandle(out: h.out, to: p); needsDisplay = true; return
        }
        if let rot = rotating {
            var degrees = -(atan2(p.y - rot.centre.y, p.x - rot.centre.x) - rot.startAngle)
                * 180 / .pi
            // Shift snaps to 15°, which is how you land on 45 or 90 by hand.
            if event.modifierFlags.contains(.shift) { degrees = (degrees / 15).rounded() * 15 }
            rotationDelta = degrees
            needsDisplay = true
            return
        }
        if let pending = pendingSegment {
            // Far enough to mean it: start bending rather than adding.
            if hypot(p.x - pending.at.x, p.y - pending.at.y) > grabRadius / 2 {
                bendingSegment = pending.index
                pendingSegment = nil
            } else {
                return
            }
        }
        if let seg = bendingSegment {
            editPath?.bend(segment: seg, to: p); needsDisplay = true; return
        }
        if let h = activeHandle, let r = selectionBounds {
            let a = resizeAnchor
            var sx: CGFloat = 1, sy: CGFloat = 1
            let startW = handlePoint(h, in: r).x - a.x
            let startH = handlePoint(h, in: r).y - a.y
            if abs(startW) > 0.001 { sx = (p.x - a.x) / startW }
            if abs(startH) > 0.001 { sy = (p.y - a.y) / startH }
            // Shift constrains to the aspect ratio, as everywhere else.
            if event.modifierFlags.contains(.shift), abs(startW) > 0.001, abs(startH) > 0.001 {
                let s = max(abs(sx), abs(sy))
                sx = s * (sx < 0 ? -1 : 1); sy = s * (sy < 0 ? -1 : 1)
            }
            resizeScale = CGSize(width: max(0.01, sx), height: max(0.01, sy))
            needsDisplay = true
            return
        }
        if marqueeing {
            marquee = CGRect(x: min(p.x, dragAnchor.x), y: min(p.y, dragAnchor.y),
                             width: abs(p.x - dragAnchor.x), height: abs(p.y - dragAnchor.y))
            needsDisplay = true
            return
        }
        guard dragging else { return }
        dragOffset = CGSize(width: p.x - dragAnchor.x, height: p.y - dragAnchor.y)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { needsDisplay = true }   // a click that commits nothing still changes what's drawn
        if draggingPoint != nil { draggingPoint = nil; commitEdit("Move Point"); return }
        if draggingHandle != nil { draggingHandle = nil; commitEdit("Adjust Handle"); return }
        if let rot = rotating {
            rotating = nil
            let d = rotationDelta
            rotationDelta = 0
            if d != 0 { onRotateEnd?(d, rot.centre) }
            return
        }
        if bendingSegment != nil { bendingSegment = nil; commitEdit("Bend Curve"); return }
        if let pending = pendingSegment {
            // Pressed and released without moving: that's a click, so add a point.
            pendingSegment = nil
            if let vp = editPath, let hit = vp.closestSegment(to: pending.at, within: grabRadius * 2) {
                insertTarget = (hit.index, pending.centred ? 0.5 : hit.t)
                insertPointAtPreview()
            }
            return
        }
        if activeHandle != nil {
            activeHandle = nil
            let s = resizeScale
            resizeScale = CGSize(width: 1, height: 1)
            onResizeEnd?(s, resizeAnchor)
            needsDisplay = true
            return
        }
        if marqueeing {
            marqueeing = false
            if let m = marquee, m.width > 2, m.height > 2 {
                onMarquee?(m, event.modifierFlags.contains(.shift))
            }
            marquee = nil
            needsDisplay = true
            return
        }
        guard dragging else { return }
        dragging = false
        let o = dragOffset
        dragOffset = .zero
        onDragEnd?(o)
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 36:   // return — finish an open path
            if tool == .pen { finishPen(close: false); return }
        case 53:   // escape — abandon
            if tool == .pen { penPoints = []; penCursor = nil; needsDisplay = true; return }
            if editingLayerID != nil { editingLayerID = nil; return }
            if enteredGroup != nil { enteredGroup = nil; return }
        case 51, 117:  // delete
            // A targeted point goes first; otherwise the whole selection goes.
            if let vp = editPath, let i = lastTouchedPoint, vp.points.count > 2 {
                editPath?.removePoint(i)
                lastTouchedPoint = nil
                commitEdit("Delete Point")
                return
            }
            onDelete?()
            return
        case 24 where event.modifierFlags.contains(.command):   // ⌘= — unshifted ⌘+
            onZoom?(.zoomIn)
            return
        case 27 where event.modifierFlags.contains(.command):   // ⌘-
            onZoom?(.zoomOut)
            return
        // Illustrator's add/remove anchor keys, live while editing a path. Bare, so
        // they don't collide with the ⌘ zoom pair above.
        // 1-4 set the selected point's type, in the order the inspector lists them.
        // CurveMode's raw values are already 1...4, so the digit IS the mode.
        case 18, 19, 20, 21:
            if editPath != nil, lastTouchedPoint != nil,
               let m = CurveMode(rawValue: Int(event.keyCode) - 17) {
                applyPointMode(m)
                return
            }
            super.keyDown(with: event)
            return
        case 24, 69:      // = / + , main row and keypad
            if editPath != nil, insertPointAtPreview() { return }
            super.keyDown(with: event)
            return
        case 27, 78:      // - / _ , main row and keypad
            if editPath != nil, removePointUnderCursor() { return }
            super.keyDown(with: event)
            return
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
///
/// It also has to catch clicks. When the page is fitted by height, the bare space to its
/// left and right belongs to the clip view, not the canvas — so clicking there never
/// reached PageCanvas and the selection wouldn't clear, while clicking above or below
/// (inside the canvas's own label margin) did. Deselecting has to work on every piece of
/// empty space, not just the parts that happen to be inside the document view.
final class CenteringClipView: NSClipView {

    /// Route every click inside the scroll area to the canvas, even the bare space
    /// beyond the page.
    ///
    /// The document view is only as big as the page plus a margin, so when a page is
    /// fitted by height the gray either side belongs to the clip view. That made
    /// deselect-by-clicking work above and below but not left or right, and made
    /// marquee-dragging impossible from exactly the empty space you'd naturally start
    /// a marquee in. Handing those points to the canvas fixes both at the source
    /// rather than patching each symptom — the canvas converts to page coordinates
    /// the same way regardless of whether the point is inside its frame.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let doc = documentView, let sup = superview,
           convert(bounds, to: sup).contains(point) {
            return doc
        }
        return super.hitTest(point)
    }

    /// Centres only what genuinely can't be scrolled.
    ///
    /// This used to re-centre on every axis where the document was smaller than the
    /// window, which is what pinned the artboards in the middle and made a sideways
    /// swipe spring back. With a canvas that extends well past the artwork it rarely
    /// applies at all; zoomed far out it still does, and there centring is right —
    /// there is nothing else to look at.
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
    @Binding var selection: Set<String>
    let zoom: ZoomRequest
    let pointMode: (serial: Int, mode: CurveMode)?
    let revision: Int
    let tool: DocumentStore.Tool
    let pageToken: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ZoomingScrollView()
        scroll.contentView = CenteringClipView()
        // Overlay scrollers: on a canvas that runs well past the artwork a permanent
        // scrollbar is both meaningless and in the way. They appear while you scroll
        // and get out of the way afterwards, which is what Sketch and Figma do.
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
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
        let pageChanged = context.coordinator.lastPageToken != pageToken
        canvas.images = images
        canvas.page = page
        canvas.selected = selection
        canvas.pageToken = pageToken
        canvas.revision = revision
        canvas.tool = tool
        wire(canvas)
        if let req = pointMode, context.coordinator.lastPointModeSerial != req.serial {
            context.coordinator.lastPointModeSerial = req.serial
            canvas.applyPointMode(req.mode)
        }
        if context.coordinator.lastZoomSerial != zoom.serial {
            context.coordinator.lastZoomSerial = zoom.serial
            apply(zoom.intent, scroll: scroll, canvas: canvas)
        }
        if pageChanged, let page {
            context.coordinator.lastPageToken = pageToken
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

    /// Carries out a zoom request against the live scroll view.
    private func apply(_ intent: ZoomIntent, scroll: NSScrollView, canvas: PageCanvas) {
        guard let zoomer = scroll as? ZoomingScrollView else { return }
        canvas.layoutSubtreeIfNeeded()
        switch intent {
        case .zoomIn:      zoomer.zoom(by: ZoomingScrollView.step)
        case .zoomOut:     zoomer.zoom(by: 1 / ZoomingScrollView.step)
        case .actualSize:  zoomer.setMagnification(1, centeredAt: canvas.contentRectInView.centre)
        case .fit:         zoomer.fit(canvas.contentRectInView)
        case .toSelection:
            // Falls back to fit rather than doing nothing, which would read as broken.
            let rect = canvas.selectionRectInView
            zoomer.fit(rect.isEmpty ? canvas.contentRectInView : rect)
        }
    }

    private func wire(_ canvas: PageCanvas) {
        canvas.onSelect = { id, extend in store.select(id, extend: extend) }
        canvas.onMarquee = { rect, extend in
            guard let p = store.page else { return }
            store.selectAll(in: rect, on: p, extend: extend)
        }
        canvas.onDragBegin = { id in store.beginDrag(id) }
        canvas.onDragEnd = { offset in store.endDrag(offset: offset) }
        canvas.onNudge = { dx, dy in store.nudge(dx: dx, dy: dy) }
        canvas.onDelete = { store.deleteSelection() }
        canvas.onZoom = { store.zoom($0) }
        canvas.onPointSelected = { i, m in
            store.editingPoint = i.flatMap { idx in m.map { DocumentStore.EditingPoint(index: idx, mode: $0) } }
        }
        canvas.onResizeBegin = { store.beginResize() }
        canvas.onResizeEnd = { scale, anchor in store.endResize(scale: scale, anchor: anchor) }
        canvas.onRotateBegin = { store.beginRotate() }
        canvas.onRotateEnd = { degrees, centre in store.endRotate(degrees: degrees, centre: centre) }
        canvas.onDrawPath = { vp in store.commitDrawnPath(vp) }
        canvas.onEditPath = { vp, id, name in store.commitEditedPath(vp, layerID: id, actionName: name) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var canvas: PageCanvas?
        var lastPageToken: Int = -1
        var lastZoomSerial: Int = 0
        var lastPointModeSerial: Int = 0
    }
}


extension CGRect {
    var centre: CGPoint { CGPoint(x: midX, y: midY) }
}


extension Array {
    /// Index that returns nil rather than trapping — point indices outlive the paths
    /// they came from when the selection changes mid-edit.
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
