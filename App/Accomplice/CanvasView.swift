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
    var selected: Set<String> = [] { didSet { updateDragSet(); rebuildEditPath(); needsDisplay = true } }
    var onClick: ((CGPoint, Bool) -> Void)?          // point, extend (shift held)
    var onMarquee: ((CGRect, Bool) -> Void)?         // rect, extend
    var onDragBegin: ((String) -> Void)?
    var onResizeBegin: (() -> Void)?
    var onResizeEnd: ((CGSize, CGPoint) -> Void)?
    var onDrawPath: ((VectorPath) -> Void)?
    var onEditPath: ((VectorPath, String, String) -> Void)?

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

    /// The selected path, exploded into editable points (page space).
    private var editPath: VectorPath?
    private var editLayerID: String?
    private var editTransform: CGAffineTransform = .identity
    private var draggingPoint: Int?
    private var draggingHandle: (index: Int, out: Bool)?
    private var bendingSegment: Int?
    private var lastTouchedPoint: Int?

    private var pointRadius: CGFloat { 4 / max(0.01, currentScale) }
    private var grabRadius: CGFloat { 7 / max(0.01, currentScale) }

    /// Rebuilds the editable point list when the selection changes.
    ///
    /// Points live in page space so hit-testing and dragging need no per-event
    /// transform maths; they're converted back into the layer's own space on commit.
    private func rebuildEditPath() {
        editPath = nil; editLayerID = nil; editTransform = .identity
        guard tool != .pen, let page, selected.count == 1, let id = selected.first,
              let l = page.layer(id), case .path(let cg, _) = l.kind else { return }
        guard let t = transformOf(id, in: page.layers, base: .identity) else { return }
        editTransform = t
        editLayerID = id
        editPath = VectorPath(cgPath: cg.transformed(by: t))
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
        let local = VectorPath(cgPath: vp.cgPath().transformed(by: editTransform.inverted()))
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
        // composedFor is cleared by `revision` when contents change, which is what
        // makes an edit rebuild this rather than redrawing stale geometry.
        composed = Compose.flatten(page.layers)
        composedFor = page.name
        artboards = []
        collectArtboards(page.layers, .identity, &artboards)
    }

    /// Identity of the page whose bounds we're currently using. A token rather than a
    /// name, because names collide across documents.
    private var boundsToken: Int = -1
    var pageToken: Int = 0 { didSet { if pageToken != oldValue { adoptPage(); needsDisplay = true } } }

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
            let margin = labelMargin
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

        let r = Renderer(images: images)
        if activeHandle != nil {
            let moved = composed.filter { dragSet.contains($0.layer.id) }
            let rest = composed.filter { !dragSet.contains($0.layer.id) }
            r.draw(drawables: rest, in: ctx)
            ctx.saveGState()
            ctx.translateBy(x: resizeAnchor.x, y: resizeAnchor.y)
            ctx.scaleBy(x: resizeScale.width, y: resizeScale.height)
            ctx.translateBy(x: -resizeAnchor.x, y: -resizeAnchor.y)
            r.draw(drawables: moved, in: ctx)
            ctx.restoreGState()
        } else if dragging && dragOffset != .zero {
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
        if event.clickCount >= 2, let vp = editPath {
            let onExisting = vp.points.contains { pt in
                hypot(p.x - pt.point.x, p.y - pt.point.y) <= grabRadius
                    || (pt.hasCurveFrom && hypot(p.x - pt.curveFrom.x, p.y - pt.curveFrom.y) <= grabRadius)
                    || (pt.hasCurveTo && hypot(p.x - pt.curveTo.x, p.y - pt.curveTo.y) <= grabRadius)
            }
            if !onExisting, let hit = vp.closestSegment(to: p, within: grabRadius * 2),
               let made = editPath?.insertPoint(onSegment: hit.index, at: hit.t) {
                lastTouchedPoint = made
                commitEdit("Add Point")
                needsDisplay = true
                return
            }
        }

        // --- Bend: grab the nearest segment of the edited path ---
        if tool == .bend, let vp = editPath,
           let hit = vp.closestSegment(to: p, within: grabRadius * 2) {
            bendingSegment = hit.index
            return
        }

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

        // Handles win over everything: they sit on the selection's edge, which is
        // usually on top of the art you'd otherwise hit.
        if let handle = handleUnder(p), let r = selectionBounds {
            activeHandle = handle
            resizeAnchor = anchorPoint(handle, in: r)
            resizeScale = CGSize(width: 1, height: 1)
            onResizeBegin?()
            return
        }

        let hit = layerHit(p)

        guard let h = hit else {
            if !extend { onClick?(p, false) }   // clears the selection
            marqueeing = true
            return
        }
        if !selected.contains(h.id) || extend { onClick?(p, extend) }
        if !extend {
            dragging = true
            onDragBegin?(h.id)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let p = CGPoint(x: local.x + bounds1.minX, y: local.y + bounds1.minY)

        if tool == .pen, !penPoints.isEmpty {
            penCursor = p
            needsDisplay = true
            return
        }

        // Show where a point would land while editing one. Double-click is not a
        // gesture anyone guesses at, so the path has to offer it.
        let wanted: CGPoint? = editPath.flatMap { vp in
            let onExisting = vp.points.contains { pt in
                hypot(p.x - pt.point.x, p.y - pt.point.y) <= grabRadius
                    || (pt.hasCurveFrom && hypot(p.x - pt.curveFrom.x, p.y - pt.curveFrom.y) <= grabRadius)
                    || (pt.hasCurveTo && hypot(p.x - pt.curveTo.x, p.y - pt.curveTo.y) <= grabRadius)
            }
            guard !onExisting, let hit = vp.closestSegment(to: p, within: grabRadius * 2),
                  let (a, b) = vp.segment(hit.index) else { return nil }
            return VectorPath.evaluate(a, b, hit.t)
        }
        if wanted != insertPreview {
            insertPreview = wanted
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if insertPreview != nil { insertPreview = nil; needsDisplay = true }
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
        if bendingSegment != nil { bendingSegment = nil; commitEdit("Bend Curve"); return }
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
    let revision: Int
    let tool: DocumentStore.Tool
    let pageToken: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ZoomingScrollView()
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
        let pageChanged = context.coordinator.lastPageToken != pageToken
        canvas.images = images
        canvas.page = page
        canvas.selected = selection
        canvas.pageToken = pageToken
        canvas.revision = revision
        canvas.tool = tool
        wire(canvas)
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
        canvas.onClick = { [weak canvas] pt, extend in
            store.select(canvas?.layerHit(pt)?.id, extend: extend)
        }
        canvas.onMarquee = { rect, extend in
            guard let p = store.page else { return }
            store.selectAll(in: rect, on: p, extend: extend)
        }
        canvas.onDragBegin = { id in store.beginDrag(id) }
        canvas.onDragEnd = { offset in store.endDrag(offset: offset) }
        canvas.onNudge = { dx, dy in store.nudge(dx: dx, dy: dy) }
        canvas.onDelete = { store.deleteSelection() }
        canvas.onZoom = { store.zoom($0) }
        canvas.onResizeBegin = { store.beginResize() }
        canvas.onResizeEnd = { scale, anchor in store.endResize(scale: scale, anchor: anchor) }
        canvas.onDrawPath = { vp in store.commitDrawnPath(vp) }
        canvas.onEditPath = { vp, id, name in store.commitEditedPath(vp, layerID: id, actionName: name) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var canvas: PageCanvas?
        var lastPageToken: Int = -1
        var lastZoomSerial: Int = 0
    }
}


extension CGRect {
    var centre: CGPoint { CGPoint(x: midX, y: midY) }
}
