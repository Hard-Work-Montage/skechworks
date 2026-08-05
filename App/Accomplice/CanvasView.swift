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
    private var editingLayerID: String? {
        didSet { rebuildEditPath(); refreshCursor(); needsDisplay = true }
    }
    /// The canvas resolves what a click means (group vs the layer inside it) before
    /// telling anyone, so selection policy lives in one place rather than in the store.
    var onSelect: ((String?, Bool) -> Void)?        // layer id, extend (shift held)
    var onMarquee: ((CGRect, Bool) -> Void)?         // rect, extend
    var onDragBegin: ((String) -> Void)?
    var onResizeBegin: (() -> Void)?
    var onResizeEnd: ((CGSize, CGPoint) -> Void)?
    var onDrawPath: ((VectorPath) -> Void)?
    var onEditPath: ((VectorPath, String, String) -> Void)?
    /// "I'm done with this tool" — the canvas can end a drawing mode, but only the
    /// store owns which tool is current, so finishing has to travel back up.
    var onExitTool: (() -> Void)?
    /// Which point is under the cursor's attention, for the Point Type control.
    var onPointSelected: ((Int?, CurveMode?) -> Void)?
    /// Inline rename, from double-clicking an artboard label. (id, new name)
    var onRenameLayer: ((String, String) -> Void)?
    /// Inline content edit, from double-clicking a text layer. (id, new string)
    var onEditTextContent: ((String, String) -> Void)?
    /// Crop mode, entered from the inspector. (id, kept region in unit coords)
    var onCommitCrop: ((String, CGRect) -> Void)?
    var onCancelCrop: (() -> Void)?
    /// A remove box on a bitmap. (id, rect in the layer's own coordinates)
    var onRemoveRect: ((String, CGRect) -> Void)?
    /// A marquee erase on a bitmap. (id, rect in the layer's own coordinates)
    var onEraseRect: ((String, CGRect) -> Void)?

    /// The bitmap being cropped; the inspector drives it through the store.
    var croppingID: String? {
        didSet {
            guard croppingID != oldValue else { return }
            beginCropDraft()
            needsDisplay = true
        }
    }
    /// The kept region while cropping, and the layer's frame, both in page coords.
    private var cropDraft: CGRect = .zero
    private var cropFrame: CGRect = .zero
    private var cropDrag: (handle: Handle?, start: CGPoint, rect: CGRect)?
    /// A marquee erase in flight: layer, its transform, and the drag in page coords.
    private var eraseRectDrag: (id: String, t: CGAffineTransform, start: CGPoint, current: CGPoint)?

    private func beginCropDraft() {
        guard let id = croppingID, let page,
              let f = frameOf(id, in: page.layers, base: .identity) else { return }
        cropFrame = f
        cropDraft = f
        window?.makeFirstResponder(self)
    }

    var tool: DocumentStore.Tool = .select {
        didSet {
            guard tool != oldValue else { return }
            if tool != .pen { finishPen(close: false) }
            rebuildEditPath()
            refreshCursor()
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
    /// Where to draw the brush outline, when the eraser is over a bitmap.
    private var brushAt: CGPoint?
    /// The segment and parameter that preview refers to, so the keyboard can use it.
    private var insertTarget: (segment: Int, t: CGFloat)?
    /// Last known pointer position in page space, for the keyboard shortcuts.
    private var hoverPoint: CGPoint?

    /// The anchor or handle the pointer is over, while point-editing.
    ///
    /// Sketch fills the point solid as you come within reach of it and swaps the cursor
    /// for an arrow. Together those say "this one, and a drag moves it" — without them
    /// the only way to find out whether you're close enough is to press and see.
    private var hoveredPoint: Int?
    private var hoveredHandle: (index: Int, out: Bool)?

    /// The selected path, exploded into editable points (page space).
    private var editPath: VectorPath?
    private var editLayerID: String?
    private var editTransform: CGAffineTransform = .identity
    /// The points picked out in the path being edited.
    ///
    /// A set, because the reason to nudge from the keyboard rather than drag is usually
    /// that several points have to move together and stay in line. Shift adds to it, the
    /// way shift does everywhere else in the app.
    private var selectedPoints: Set<Int> = [] {
        didSet { if selectedPoints != oldValue { needsDisplay = true } }
    }

    private var draggingPoint: Int?
    private var draggingHandle: (index: Int, out: Bool)?
    /// Whether the point drag in flight has actually gone anywhere.
    private var pointDragMoved = false
    /// Whether shift was down for the press that started this point drag.
    private var pressExtended = false
    /// Where every selected point stood when the drag began.
    ///
    /// Dragging works off a delta from the press rather than snapping the point to the
    /// pointer: with more than one selected there's no single point to snap, and even
    /// with one it means grabbing slightly off-centre doesn't jerk it under the cursor.
    private var dragPointStart: [Int: CGPoint] = [:]
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
        let was = editLayerID
        defer { reconcilePointSelection(previousLayer: was) }
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

    /// Keeps the picked points honest across a rebuild.
    ///
    /// This runs on every content change, including the one a nudge itself causes, so it
    /// can't simply clear. Moving to a different shape drops the selection; within the
    /// same one, indices that no longer exist are dropped and the rest stand.
    private func reconcilePointSelection(previousLayer: String?) {
        guard editLayerID != nil, editLayerID == previousLayer, let vp = editPath else {
            selectedPoints = []
            lastTouchedPoint = nil
            return
        }
        selectedPoints = selectedPoints.filter { vp.points.indices.contains($0) }
        if let i = lastTouchedPoint, !vp.points.indices.contains(i) { lastTouchedPoint = nil }
    }

    /// Adds a point to the picked set, or replaces it.
    ///
    /// A plain click on one that's already picked leaves the set alone, so a drag
    /// starting on one of several selected points moves all of them rather than
    /// throwing the rest away first.
    private func selectPoint(_ i: Int, extend: Bool) {
        if extend {
            if selectedPoints.contains(i) { selectedPoints.remove(i) } else { selectedPoints.insert(i) }
        } else if !selectedPoints.contains(i) {
            selectedPoints = [i]
        }
        lastTouchedPoint = selectedPoints.contains(i) ? i : selectedPoints.sorted().first
    }

    /// Moves every picked point. One arrow press, one undo step, like nudging a layer.
    @discardableResult
    private func nudgePoints(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
        guard let vp = editPath, !selectedPoints.isEmpty else { return false }
        for i in selectedPoints where vp.points.indices.contains(i) {
            let at = vp.points[i].point
            editPath?.points[i].move(to: CGPoint(x: at.x + dx, y: at.y + dy))
        }
        commitEdit(selectedPoints.count == 1 ? "Nudge Point" : "Nudge Points")
        needsDisplay = true
        return true
    }

    /// Removes every picked point, deepest index first so the rest keep their numbers.
    @discardableResult
    private func removeSelectedPoints() -> Bool {
        guard let vp = editPath, !selectedPoints.isEmpty else { return false }
        // A path needs two points to still be a path.
        let going = selectedPoints.sorted(by: >).prefix(max(0, vp.points.count - 2))
        guard !going.isEmpty else { return false }
        for i in going { editPath?.removePoint(i) }
        selectedPoints = []
        lastTouchedPoint = nil
        commitEdit(going.count == 1 ? "Delete Point" : "Delete Points")
        refreshInsertPreview()
        needsDisplay = true
        return true
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
    var onErase: ((String, [CGPoint]) -> Void)?
    /// Brush size and softness, in page units, supplied by the store.
    var eraseRadius: CGFloat = 24
    var eraseSoftness: CGFloat = 0.5

    /// The stroke in progress, in the target layer's own coordinates.
    private var erasing: (layer: String, points: [CGPoint], transform: CGAffineTransform)?

    /// Live drag state. The model isn't touched until mouse-up; until then the canvas
    /// just offsets the already-composed drawables belonging to the dragged subtree.
    /// Recomposing per frame would cost ~0.6s of CGPath boolean work per tick.
    private var dragOffset: CGSize = .zero
    private var dragging = false

    /// Guides for the snap currently in force, in page coordinates. Cleared on
    /// mouse-up along with everything else about the gesture.
    private var snapGuides: [Snapping.Guide] = []

    /// Rectangles to snap against, gathered once when the drag starts.
    ///
    /// Once, not per frame: the set can't change mid-drag, and walking the layer tree
    /// on every mouse-move is the sort of thing that makes a big document feel slow
    /// for no reason.
    private var snapTargets: [CGRect] = []
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

    /// The selection, for zoom-to-selection. Empty when nothing is selected, which
    /// the caller treats as "fit the page instead".
    var selectionRectInView: CGRect { selectionBounds ?? .zero }

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
        if tool == .erase {
            // The ring IS the size control: you can see how big the brush is before
            // committing a stroke you'd have to undo to judge.
            brushAt = bitmapHit(p) != nil ? p : nil
            needsDisplay = true
            NSCursor.crosshair.set()
            return
        }
        if brushAt != nil { brushAt = nil; needsDisplay = true }
        if tool == .remove {
            NSCursor.crosshair.set()
            return
        }
        if tool == .pen {
            // The badge is the whole point of drawing our own: it says whether this
            // click extends the path or shuts it, which is the one thing the canvas
            // can't tell you — the first point looks like every other point.
            VectorCursors.pen(penWouldClose(at: p) ? .close : .add).set()
            return
        }
        if editPath != nil {
            // Three different clicks live on top of each other in point editing, so the
            // cursor has to name which one is armed: move what's under the pointer, add
            // a point to the segment, or leave the mode.
            if hoveredPoint != nil || hoveredHandle != nil { VectorCursors.movePoint.set() }
            else if insertPreview != nil { VectorCursors.pen(.add).set() }
            else { NSCursor.arrow.set() }
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

    /// True when a pen click at `p` would close the path rather than extend it.
    private func penWouldClose(at p: CGPoint) -> Bool {
        guard let first = penPoints.first, penPoints.count >= 2 else { return false }
        return hypot(p.x - first.point.x, p.y - first.point.y) <= grabRadius
    }

    /// Re-picks the cursor without waiting for a mouse move.
    ///
    /// Entering a tool has to change the pointer straight away. Otherwise the pen looks
    /// like it hasn't started until you twitch the mouse, which reads as the click on
    /// the toolbar not having landed.
    private func refreshCursor() {
        window?.invalidateCursorRects(for: self)
        guard let p = hoverPoint else {
            if tool == .pen { VectorCursors.pen(.add).set() }
            return
        }
        // Entering point editing happens with the pointer already sitting on the shape,
        // so what it's over has to be worked out here rather than waiting for a move.
        refreshHover(at: p)
        refreshInsertPreview()
        updateCursor(at: p)
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

    /// The page point sitting at the view's top-left, and how much it's magnified.
    ///
    /// This is the whole of the canvas geometry. There is no document view sized to
    /// the artwork and no scroll bounds, which is what "infinite" means: panning just
    /// moves the origin and nothing clamps it. It also removes a class of problems
    /// that came with the old model — the clip view re-centring anything smaller than
    /// the window, and fitting against a frame that hadn't been resized yet.
    private(set) var origin: CGPoint = .zero { didSet { publishViewport() } }
    private(set) var scale: CGFloat = 1 { didSet { publishViewport() } }

    /// Reports where the canvas is looking, for tests.
    ///
    /// The artboard labels are drawn with Core Graphics and aren't in the
    /// accessibility tree, so from outside the app there is otherwise nothing that
    /// moves when you pan — a test asking whether scrolling worked would be reading
    /// the layer list and always seeing the same answer.
    private func publishViewport() {
        setAccessibilityIdentifier("canvas-viewport")
        setAccessibilityValue("\(Int(origin.x)),\(Int(origin.y)),\(String(format: "%.3f", scale))")
    }

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
        composedGen += 1
        artboards = []
        collectArtboards(page.layers, .identity, &artboards)
    }

    /// Bumped whenever the static composition is rebuilt — the backdrop cache's
    /// signal that its pixels are stale.
    private var composedGen = 0

    /// Identity of the page whose bounds we're currently using. A token rather than a
    /// name, because names collide across documents.
    private var boundsToken: Int = -1
    var pageToken: Int = 0 { didSet { if pageToken != oldValue { adoptPage(); needsDisplay = true } } }
    /// The canvas has no size of its own: it is a window onto an unbounded page, and
    /// there is no document frame to keep in step with the artwork. What used to live
    /// here — a margin, a frame resize, and code to compensate the scroll when the
    /// frame grew at the top or left — all existed to fake that.
    private func adoptPage() {
        guard page != nil else { boundsToken = -1; return }
        if boundsToken != pageToken {
            boundsToken = pageToken
            composedFor = nil
        }
        recompose()
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

    /// The artwork, in page coordinates. What zoom-to-fit aims at.
    var contentRectInView: CGRect { page?.contentBounds() ?? bounds }

    /// The rasterized artwork at the current viewport, reused until content, zoom,
    /// or scroll changes. Fireworks' trick: on a 5,000-path page, a selection tick
    /// or marquee frame costs a bitmap blit instead of re-rasterizing every path.
    private var backdrop: CGImage?
    private var backdropKey = ""

    /// Canvas fill, artwork (culled to the viewport) and artboard hairlines — the
    /// pixels that are identical from frame to frame while nothing is being edited.
    /// Draws in view coordinates; shared by the live path and the backdrop cache.
    private func drawContent(_ ctx: CGContext, viewSize: CGSize) {
        // Nothing behind the canvas any more, so it paints the surround itself.
        ctx.setFillColor(Palette.canvas.cgColor)
        ctx.fill(CGRect(origin: .zero, size: viewSize))

        // No page background. A Sketch-style canvas is infinite and unpainted — only
        // artboards have a colour. Filling the view white made every page look like one
        // big artboard and hid where the real ones start and stop.
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -origin.x, y: -origin.y)
        let visible = CGRect(x: origin.x, y: origin.y,
                             width: viewSize.width / scale, height: viewSize.height / scale)
        Renderer(images: images).draw(drawables: composed, in: ctx, visible: visible)

        // A hairline round each artboard. On a light canvas a white board has no edge
        // of its own, and knowing where the page stops is most of what an artboard is
        // for. Editor chrome only — it never reaches an export.
        ctx.setStrokeColor(Palette.divider.cgColor)
        ctx.setLineWidth(1 / max(0.01, currentScale))
        for ab in artboards { ctx.stroke(ab.frame) }
        ctx.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard let page else {
            Palette.canvas.setFill()
            dirtyRect.fill()
            return
        }

        if liveGesture != nil {
            // Mid-gesture the artwork changes every frame; draw it directly.
            backdrop = nil
            backdropKey = ""
            drawContent(ctx, viewSize: bounds.size)
        } else {
            let bs = window?.backingScaleFactor ?? 2
            let appearance = effectiveAppearance.name.rawValue
            let key = "\(composedGen)|\(scale)|\(origin.x),\(origin.y)|\(bounds.size)|\(bs)|\(images.count)|\(appearance)"
            if backdrop == nil || backdropKey != key {
                let w = max(1, Int(bounds.width * bs)), h = max(1, Int(bounds.height * bs))
                if let bctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    // The bitmap is bottom-up while the view is flipped; mirror once
                    // here so the cached pixels match the view exactly.
                    bctx.translateBy(x: 0, y: CGFloat(h))
                    bctx.scaleBy(x: bs, y: -bs)
                    drawContent(bctx, viewSize: bounds.size)
                    backdrop = bctx.makeImage()
                    backdropKey = key
                }
            }
            if let backdrop {
                ctx.saveGState()
                // Un-flip to blit, then the chrome below draws flipped as before.
                ctx.translateBy(x: 0, y: bounds.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(backdrop, in: CGRect(origin: .zero, size: bounds.size))
                ctx.restoreGState()
            } else {
                drawContent(ctx, viewSize: bounds.size)
            }
        }

        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -origin.x, y: -origin.y)

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

        drawSnapGuides(ctx)
        drawHandles(ctx)
        drawPointOverlay(ctx)
        drawPenPreview(ctx)
        drawArtboardLabels()
        drawCropOverlay(ctx)
        if let er = eraseRectDrag {
            let r = CGRect(x: min(er.start.x, er.current.x), y: min(er.start.y, er.current.y),
                           width: abs(er.current.x - er.start.x), height: abs(er.current.y - er.start.y))
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(1 / sc)
            ctx.setLineDash(phase: 0, lengths: [4 / sc, 3 / sc])
            ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.restoreGState()
        drawBrush(ctx)
        drawMinimap(ctx)
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
            for (has, h, out) in [(p.hasCurveFrom, p.curveFrom, true),
                                  (p.hasCurveTo, p.curveTo, false)] where has {
                ctx.move(to: p.point); ctx.addLine(to: h)
                ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor)
                ctx.setLineWidth(1 / sc)
                ctx.strokePath()
                let warm = hoveredHandle?.index == i && hoveredHandle?.out == out
                let hr = pointRadius * (warm ? 1.1 : 0.8)
                let hbox = CGRect(x: h.x - hr, y: h.y - hr, width: hr * 2, height: hr * 2)
                ctx.setFillColor(NSColor.controlAccentColor.cgColor)
                ctx.fillEllipse(in: hbox)
                if warm {
                    ctx.setStrokeColor(NSColor.white.cgColor)
                    ctx.setLineWidth(1.4 / sc)
                    ctx.strokeEllipse(in: hbox)
                }
            }
            // Three states, and they have to be three pictures. Picked points stay
            // filled so you can see what an arrow key is about to move; the one under
            // the pointer fills part-way, which reads as "this is the one you'd get";
            // and everything else stays hollow. A hollow point that stays hollow when
            // you reach it gives you nothing to aim at, so you find the grab radius by
            // missing it.
            let picked = selectedPoints.contains(i)
            let warm = hoveredPoint == i
            let r = pointRadius * (picked || warm ? (picked && warm ? 1.3 : 1.15) : 1)
            let box = CGRect(x: p.point.x - r, y: p.point.y - r, width: r * 2, height: r * 2)
            let accent = NSColor.controlAccentColor
            ctx.setFillColor(picked ? accent.cgColor
                             : warm ? accent.withAlphaComponent(0.55).cgColor
                             : NSColor.white.cgColor)
            ctx.setStrokeColor(picked || warm ? NSColor.white.cgColor : accent.cgColor)
            ctx.setLineWidth(1.4 / sc)
            // Corners draw square, smooth points round — the shape tells you the mode.
            if p.isCorner { ctx.fill(box); ctx.stroke(box) }
            else { ctx.fillEllipse(in: box); ctx.strokeEllipse(in: box) }
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

    /// The lines that explain a snap.
    ///
    /// Drawn at a constant screen width so they stay hairlines at any zoom, and in the
    /// accent colour rather than Sketch's red — red on this canvas reads as an error.
    private func drawSnapGuides(_ ctx: CGContext) {
        guard !snapGuides.isEmpty else { return }
        let sc = max(0.01, currentScale)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1 / sc)
        for g in snapGuides {
            ctx.beginPath()
            if g.vertical {
                ctx.move(to: CGPoint(x: g.position, y: g.from))
                ctx.addLine(to: CGPoint(x: g.position, y: g.to))
            } else {
                ctx.move(to: CGPoint(x: g.from, y: g.position))
                ctx.addLine(to: CGPoint(x: g.to, y: g.position))
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
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
    /// Everything outside the crop dims; the window gets a bright edge and the
    /// eight handles selection boxes taught everyone to expect.
    private func drawCropOverlay(_ ctx: CGContext) {
        guard croppingID != nil else { return }
        let visible = CGRect(origin: origin,
                             size: CGSize(width: bounds.width / scale, height: bounds.height / scale))
        ctx.saveGState()
        let outside = CGMutablePath()
        outside.addRect(visible)
        outside.addRect(cropDraft)
        ctx.addPath(outside)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5 / scale)
        ctx.stroke(cropDraft)
        let s: CGFloat = 7 / scale
        for h in [Handle.nw, .n, .ne, .e, .se, .s, .sw, .w] {
            let c = handlePoint(h, in: cropDraft)
            let box = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(box)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1 / scale)
            ctx.stroke(box)
        }
        ctx.restoreGState()
    }

    private func drawArtboardLabels() {
        guard !artboards.isEmpty else { return }
        let scale = max(0.01, currentScale)
        let size = 11 / scale
        let gap = 5 / scale

        for i in artboards.indices {
            let ab = artboards[i]
            // The label being renamed shows only as the text field sitting on top —
            // drawing it too left the old name peeking out from underneath.
            if ab.id == labelEditingID { continue }
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

    // MARK: - Inline label rename

    private var labelEditor: NSTextField?
    private var labelEditingID: String?
    private var labelNameBeforeEdit = ""
    /// True while the editor holds a text layer's CONTENT rather than a name.
    private var labelEditIsText = false

    /// Edit a text layer's words right where they sit.
    private func beginTextEdit(_ l: Layer, _ run: TextRun) {
        endLabelEdit(commit: true)
        guard let page,
              let f = { () -> CGRect? in
                  guard let t = transformOf(l.id, in: page.layers, base: .identity) else { return nil }
                  return CGRect(origin: .zero, size: l.frame.size).applying(t)
              }() else { return }
        let v = viewPoint(f.origin)
        let frame = CGRect(x: v.x - 2, y: v.y - 2,
                           width: max(160, f.width * scale + 8),
                           height: max(24, f.height * scale + 6))
        let tf = NSTextField(frame: frame)
        tf.stringValue = run.string
        // Match the artwork's size on screen so the words don't jump scale mid-edit.
        tf.font = NSFont(name: run.fontName, size: max(9, min(64, run.fontSize * scale)))
            ?? .systemFont(ofSize: 13)
        tf.isBordered = true
        tf.bezelStyle = .roundedBezel
        tf.usesSingleLineMode = false
        tf.cell?.wraps = true
        tf.delegate = self
        addSubview(tf)
        window?.makeFirstResponder(tf)
        tf.selectText(nil)
        labelEditor = tf
        labelEditingID = l.id
        labelNameBeforeEdit = run.string
        labelEditIsText = true
        needsDisplay = true
    }

    private func beginLabelEdit(_ ab: ArtboardLabel) {
        endLabelEdit(commit: true)
        let v = viewPoint(ab.hit.origin)
        // Roomier than the label itself, so a longer name has somewhere to go
        // while it's being typed.
        let frame = CGRect(x: v.x - 2, y: v.y - 2,
                           width: max(160, ab.hit.width * scale + 24),
                           height: max(20, ab.hit.height * scale + 4))
        let tf = NSTextField(frame: frame)
        tf.stringValue = ab.name
        tf.font = .systemFont(ofSize: 11)
        tf.isBordered = true
        tf.bezelStyle = .roundedBezel
        tf.delegate = self
        addSubview(tf)
        window?.makeFirstResponder(tf)
        tf.selectText(nil)
        labelEditor = tf
        labelEditingID = ab.id
        labelNameBeforeEdit = ab.name
        labelEditIsText = false
        needsDisplay = true    // hide the drawn label while the field covers it
    }

    private func endLabelEdit(commit: Bool) {
        guard let tf = labelEditor else { return }
        let id = labelEditingID
        let isText = labelEditIsText
        labelEditor = nil
        labelEditingID = nil
        labelEditIsText = false
        tf.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true    // the drawn label comes back
        guard commit, let id else { return }
        let value = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != labelNameBeforeEdit else { return }
        if isText { onEditTextContent?(id, value) } else { onRenameLayer?(id, value) }
    }

    private var currentScale: CGFloat { scale }

    /// Page coordinates for a point in the view.
    private func pagePoint(_ v: CGPoint) -> CGPoint {
        CGPoint(x: v.x / scale + origin.x, y: v.y / scale + origin.y)
    }

    /// Where a page point lands in the view.
    private func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) * scale, y: (p.y - origin.y) * scale)
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(origin: viewPoint(r.origin),
               size: CGSize(width: r.width * scale, height: r.height * scale))
    }

    /// The brush outline, drawn in page space so it scales with the artwork.
    private func drawBrush(_ ctx: CGContext) {
        guard tool == .erase, let p = brushAt else { return }
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -origin.x, y: -origin.y)
        let ring = CGRect(x: p.x - eraseRadius, y: p.y - eraseRadius,
                          width: eraseRadius * 2, height: eraseRadius * 2)
        ctx.setLineWidth(1 / max(0.01, scale))
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.strokeEllipse(in: ring)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.strokeEllipse(in: ring.insetBy(dx: -1 / max(0.01, scale), dy: -1 / max(0.01, scale)))
        ctx.restoreGState()
    }

    // MARK: - Minimap

    /// The card's place in the view: bottom-left, clear of the status line.
    private var minimapRect: CGRect {
        CGRect(x: 16, y: bounds.height - 120 - 40, width: 160, height: 120)
    }

    /// What's on screen, in page coordinates.
    var visiblePageRect: CGRect {
        CGRect(origin: origin, size: CGSize(width: bounds.width / scale,
                                            height: bounds.height / scale))
    }

    private var minimapNeeded: Bool {
        guard let page, editPath == nil else { return false }
        return Minimap.isNeeded(content: page.contentBounds(), visible: visiblePageRect)
    }

    private func drawMinimap(_ ctx: CGContext) {
        guard minimapNeeded, let page else { return }
        let card = minimapRect
        let content = page.contentBounds()
        let t = Minimap.transform(content: content, visible: visiblePageRect, into: card.size)

        ctx.saveGState()
        // The card itself: a panel floating over the canvas, same language as the rails.
        let rounded = CGPath(roundedRect: card, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(rounded)
        ctx.setFillColor(Palette.rail.withAlphaComponent(0.92).cgColor)
        ctx.fillPath()
        ctx.addPath(rounded)
        ctx.setStrokeColor(Palette.divider.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        ctx.addPath(rounded)
        ctx.clip()
        ctx.translateBy(x: card.minX, y: card.minY)

        // Each artboard, or the artwork's extent when there are none.
        let boards = artboards.isEmpty ? [content] : artboards.map(\.frame)
        ctx.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor)
        for b in boards {
            let r = b.applying(t)
            ctx.fill(r.insetBy(dx: -0.5, dy: -0.5))
        }

        // Where you're looking.
        let view = visiblePageRect.applying(t)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(view)
        ctx.restoreGState()
    }

    /// Clicking the card jumps to that part of the page — the way back, not just a
    /// picture of where you aren't.
    private func minimapJump(_ p: CGPoint) -> Bool {
        guard minimapNeeded, let page, minimapRect.contains(p) else { return false }
        let card = minimapRect
        let t = Minimap.transform(content: page.contentBounds(),
                                  visible: visiblePageRect, into: card.size)
        let inCard = CGPoint(x: p.x - card.minX, y: p.y - card.minY)
        let target = inCard.applying(t.inverted())
        origin = CGPoint(x: target.x - bounds.width / (2 * scale),
                         y: target.y - bounds.height / (2 * scale))
        needsDisplay = true
        return true
    }

    /// The page point at the middle of the window, which is what zooming in and out
    /// from the keyboard should keep still.
    var pageCentre: CGPoint { pagePoint(CGPoint(x: bounds.midX, y: bounds.midY)) }

    /// Pans by a delta in view pixels.
    func pan(byViewDelta d: CGSize) {
        origin.x -= d.width / scale
        origin.y -= d.height / scale
        needsDisplay = true
    }

    /// Zooms about a page point, so what's under the pointer stays under it.
    func zoom(to newScale: CGFloat, around anchor: CGPoint) {
        let clamped = max(0.01, min(64, newScale))
        guard clamped != scale else { return }
        let before = viewPoint(anchor)
        scale = clamped
        let after = viewPoint(anchor)
        origin.x += (after.x - before.x) / scale
        origin.y += (after.y - before.y) / scale
        needsDisplay = true
    }

    /// Scales and centres so `rect` (page space) fills the view.
    func fit(_ rect: CGRect) {
        let size = bounds.size
        guard rect.width > 0, rect.height > 0, size.width > 1, size.height > 1 else { return }
        scale = max(0.01, min(64, min(size.width / rect.width, size.height / rect.height) * 0.94))
        origin = CGPoint(x: rect.midX - size.width / (2 * scale),
                         y: rect.midY - size.height / (2 * scale))
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        // scrollingDelta is what a trackpad and a modern mouse report; deltaY is the
        // older line-based value, and some events carry only that.
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if dx == 0, dy == 0 { dx = event.deltaX * 10; dy = event.deltaY * 10 }

        if event.modifierFlags.contains(.command) {
            // Zoom about the pointer. exp() keeps it symmetric, so scrolling up then
            // down comes back to where it started.
            let raw = dy
            guard raw != 0 else { return }
            let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.06
            zoom(to: scale * exp(raw * sensitivity),
                 around: pagePoint(convert(event.locationInWindow, from: nil)))
            return
        }
        // Nothing clamps this. Pan as far as you like in any direction.
        pan(byViewDelta: CGSize(width: dx, height: dy))
    }

    override func magnify(with event: NSEvent) {
        zoom(to: scale * (1 + event.magnification),
             around: pagePoint(convert(event.locationInWindow, from: nil)))
    }

    /// Walks to the selected layer, accumulating transforms, and returns its canvas frame.
    private func frameOf(_ id: String, in layers: [Layer], base: CGAffineTransform) -> CGRect? {
        for l in layers {
            let t = Compose.transform(l).concatenating(base)
            if l.id == id {
                // An artboard's edge IS its geometry — Sketch highlights the frame,
                // not the artwork. Union-of-children here made a selected artboard
                // wear its content's handles, which read as the child being selected.
                if l.isArtboard { return CGRect(origin: .zero, size: l.frame.size).applying(t) }
                // Groups measure what they PAINT. resolvedPath only merges vector
                // children, so a group holding a bitmap and a rect wore a selection
                // box around just the rect. visibleBounds walks the same drawables
                // the renderer does — bitmaps and text included — and respects masks.
                if case .group = l.kind {
                    return Compose.visibleBounds(of: l, base: base)
                }
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
    /// The bitmap under a point. Erasing only applies to images — there's nothing to
    /// rub out of a vector shape, and quietly doing nothing is worse than not offering
    /// the tool at all.
    private func bitmapHit(_ point: CGPoint) -> Layer? {
        for d in composed.reversed() where d.imageRef != nil {
            let r = CGRect(origin: .zero, size: d.layer.frame.size).applying(d.transform)
            if r.contains(point) { return d.layer }
        }
        return nil
    }

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

    /// The deepest path inside a combined shape whose fill sits under the point.
    ///
    /// Members are walked front-first, so on a Subtract the cut-out wins over the
    /// base it was cut from — clicking the black between the eyes lands on the face,
    /// clicking an eye's edge lands on the eye.
    private func memberPathHit(in group: Layer, at p: CGPoint) -> String? {
        guard let page,
              let base = transformOf(group.id, in: page.layers, base: .identity) else { return nil }
        func search(_ children: [Layer], _ base: CGAffineTransform) -> String? {
            for m in children.reversed() where m.isVisible {
                let t = Compose.transform(m).concatenating(base)
                switch m.kind {
                case .group(let k), .shapeGroup(let k, _):
                    if let hit = search(k, t) { return hit }
                case .path:
                    if let path = Compose.resolvedPath(m),
                       path.transformed(by: t).contains(p, using: .winding) { return m.id }
                default: continue
                }
            }
            return nil
        }
        return search(page.children(of: group.id), base)
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

    /// A layer is untouchable when it, or anything above it, is locked.
    private func lockedDeep(_ id: String) -> Bool {
        guard let page else { return false }
        if page.layer(id)?.isLocked == true { return true }
        return page.ancestors(of: id).contains { page.layer($0)?.isLocked == true }
    }

    func layerHit(_ point: CGPoint) -> Layer? {
        // Labels win over content: they sit outside the board, and they're the only
        // way to grab the artboard rather than the art sitting on it.
        if let ab = artboards.first(where: { $0.hit.contains(point) }),
           let page, let l = page.layer(ab.id), !l.isLocked {
            return l
        }
        for d in composed.reversed() {
            // Locked means the click sails through to whatever is underneath.
            if lockedDeep(d.layer.id) { continue }
            // Clipped away is gone: art overflowing its artboard (or mask) can't be
            // hit where it isn't painted, so a click on one panel can never select
            // the invisible tail of a neighbouring panel's art.
            if let c = d.clip, !c.contains(point) { continue }
            if let p = d.path, p.contains(point) { return d.layer }
            if d.path == nil {
                // The pathless rect test is for text and bitmaps, which have no
                // outline to test. A group-shadow's open/close markers are pathless
                // too but span their whole container — hit-testing those made a
                // shadowed artboard swallow every click meant for the art inside it.
                guard d.text != nil || d.imageRef != nil else { continue }
                let r = CGRect(origin: .zero, size: d.layer.frame.size).applying(d.transform)
                if r.contains(point) { return d.layer }
            }
        }
        return nil
    }

    // MARK: - Right-click

    /// Closures for the current context menu, indexed by item tag. Rebuilt per
    /// right-click; NSMenuItem can't hold a closure itself.
    private var menuActions: [() -> Void] = []
    var onToggleLock: (() -> Void)?
    var onToggleHide: (() -> Void)?

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        guard menuActions.indices.contains(sender.tag) else { return }
        menuActions[sender.tag]()
    }

    private func menuItem(_ title: String, checked: Bool = false,
                          _ block: @escaping () -> Void) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
        it.target = self
        it.tag = menuActions.count
        it.state = checked ? .on : .off
        menuActions.append(block)
        return it
    }

    /// Fireworks' right-click: every layer under the pointer, front to back —
    /// Select Behind without a modifier to memorise — then the verbs.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard tool == .select else { return nil }
        let p = pagePoint(convert(event.locationInWindow, from: nil))
        menuActions = []
        let menu = NSMenu()

        // Everything under the point, front-most first, resolved the way a click
        // would resolve it (group over member), deduplicated.
        var targets: [Layer] = []
        var seen: Set<String> = []
        for d in composed.reversed() {
            let contains: Bool
            if let path = d.path { contains = path.contains(p) }
            else if d.text != nil || d.imageRef != nil {
                contains = CGRect(origin: .zero, size: d.layer.frame.size)
                    .applying(d.transform).contains(p)
            } else { contains = false }
            guard contains, !d.isArtboardBackground else { continue }
            if let c = d.clip, !c.contains(p) { continue }
            let t = selectionTarget(d.layer, drill: false)
            if seen.insert(t.id).inserted { targets.append(t) }
        }
        if !targets.isEmpty {
            menu.addItem(.sectionHeader(title: "Layers Here"))
            for t in targets {
                let name = t.name.isEmpty ? "Layer" : t.name
                let locked = lockedDeep(t.id)
                let item = menuItem(locked ? "\(name) 🔒" : name,
                                    checked: selected.contains(t.id)) { [weak self] in
                    self?.onSelect?(t.id, false)
                }
                item.indentationLevel = 1
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let hasSelection = !selected.isEmpty
        if hasSelection {
            let page = self.page
            let allLocked = selected.allSatisfy { page?.layer($0)?.isLocked == true }
            menu.addItem(menuItem(allLocked ? "Unlock" : "Lock") { [weak self] in
                self?.onToggleLock?()
            })
            menu.addItem(menuItem("Hide") { [weak self] in self?.onToggleHide?() })
            menu.addItem(.separator())
            menu.addItem(menuItem("Delete") { [weak self] in self?.onDelete?() })
        }
        return menu.items.isEmpty ? nil : menu
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        publishViewport()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }

    override func mouseDown(with event: NSEvent) {
        // The minimap is drawn in view coordinates and floats above everything, so it
        // takes the click before the artwork does.
        if minimapJump(convert(event.locationInWindow, from: nil)) { return }

        let p = pagePoint(convert(event.locationInWindow, from: nil))

        // --- Crop mode swallows the mouse: handles, or move the window ---
        if croppingID != nil {
            if let h = cropHandleHit(p) { cropDrag = (h, p, cropDraft); return }
            if cropDraft.contains(p) { cropDrag = (nil, p, cropDraft); return }
            return   // outside: stay in the mode; Enter and Escape are the exits
        }

        // --- Erase: paint on the bitmap under the pointer ---
        if tool == .erase {
            // ⌥-drag cuts a straight-edged rectangle instead of painting.
            if event.modifierFlags.contains(.option),
               let target = bitmapHit(p),
               let t = transformOf(target.id, in: page?.layers ?? [], base: .identity) {
                eraseRectDrag = (target.id, t, p, p)
                needsDisplay = true
                return
            }
            if let target = bitmapHit(p), let t = transformOf(target.id, in: page?.layers ?? [], base: .identity) {
                erasing = (target.id, [p.applying(t.inverted())], t)
                needsDisplay = true
            }
            return
        }

        // --- Remove: box the thing on the bitmap that should go ---
        if tool == .remove {
            if let target = bitmapHit(p),
               let t = transformOf(target.id, in: page?.layers ?? [], base: .identity) {
                eraseRectDrag = (target.id, t, p, p)
                needsDisplay = true
            }
            return
        }

        dragAnchor = p
        dragOffset = .zero
        snapGuides = []
        marquee = nil
        let extend = event.modifierFlags.contains(.shift)

        // Clicking inside the current selection starts a drag; clicking elsewhere
        // re-selects first, so a single press can select and then move. Clicking bare
        // canvas starts a marquee instead.
        window?.makeFirstResponder(self)

        // --- Pen: click to drop a corner point ---
        if tool == .pen {
            if penWouldClose(at: p) {
                finishPen(close: true)          // clicking the first point closes it
                onExitTool?()                  // …and the shape is done, so hand back the cursor
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
        // Double-click an artboard's label to rename it in place — type, Enter,
        // done. The single-click that selects the board still works; this only
        // takes the second click.
        if event.clickCount >= 2, tool == .select,
           let ab = artboards.first(where: { $0.hit.contains(p) }) {
            beginLabelEdit(ab)
            return
        }

        // Double-click inside a subtracted hole: the composed fill has nothing there,
        // so the normal hit walks straight past the shape and lands on the artboard —
        // Sketch's only way back in is the layer list. But the member that CUT the
        // hole still covers that point, so the cut-out itself can be found and edited
        // from the canvas.
        if event.clickCount >= 2, editPath == nil, tool == .select {
            let plain = layerHit(p)
            if plain == nil || plain?.isArtboard == true {
                for d in composed.reversed() {
                    guard case .shapeGroup = d.layer.kind,
                          let member = memberPathHit(in: d.layer, at: p) else { continue }
                    enteredGroup = d.layer.id
                    editingLayerID = member
                    onSelect?(member, false)
                    return
                }
            }
        }

        if event.clickCount >= 2, editPath == nil, tool == .select, let leaf = layerHit(p) {
            // Already on the layer itself and it's a path: the next step in is its
            // points.
            if selected == [leaf.id], case .path = leaf.kind {
                editingLayerID = leaf.id
                return
            }
            // A text layer's next step in is its words — edit in place, the way
            // Fireworks always did.
            if selected == [leaf.id], case .text(let run) = leaf.kind {
                beginTextEdit(leaf, run)
                return
            }
            // A combined shape (Subtract, Union…) composes to one drawable, so the
            // group is all a click can hit — there is no plain path to step onto, and
            // without this the double-click just re-selected the group forever. Go
            // straight to the points of the member under the pointer instead, the
            // same one gesture a plain path gets. A member picked in the layer list
            // counts too: double-clicking the shape then edits that member's points
            // rather than bouncing back out to the group.
            if case .shapeGroup = leaf.kind,
               selected == [leaf.id]
                || (selected.count == 1
                    && page?.ancestors(of: selected.first!).contains(leaf.id) == true),
               let member = memberPathHit(in: leaf, at: p) {
                enteredGroup = leaf.id
                editingLayerID = member
                onSelect?(member, false)
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


        // --- Double-click a point to curve it, and again to straighten it ---
        //
        // The pen drops straight points, which is right for tracing an outline click by
        // click, but the outline itself is mostly curves. Going through the Point Type
        // control for each one means leaving the drawing to do it; Sketch makes it a
        // double-click, which is quick enough to do without breaking the trace.
        if event.clickCount >= 2, let vp = editPath,
           let i = vp.points.firstIndex(where: { hypot(p.x - $0.point.x, p.y - $0.point.y) <= grabRadius }) {
            draggingPoint = nil
            selectPoint(i, extend: false)
            // Mirrored, not asymmetric: with both handles equal and opposite one drag
            // shapes the curve on either side, which is what you want while tracing.
            applyPointMode(vp.points[i].isCorner ? .mirrored : .straight)
            refreshHover(at: p)
            return
        }

        // --- Point editing on the selected path ---
        if let vp = editPath {
            for (i, pt) in vp.points.enumerated() {
                if pt.hasCurveFrom, hypot(p.x - pt.curveFrom.x, p.y - pt.curveFrom.y) <= grabRadius {
                    draggingHandle = (i, true); pointDragMoved = false; refreshHover(at: p); return
                }
                if pt.hasCurveTo, hypot(p.x - pt.curveTo.x, p.y - pt.curveTo.y) <= grabRadius {
                    draggingHandle = (i, false); pointDragMoved = false; refreshHover(at: p); return
                }
            }
            for (i, pt) in vp.points.enumerated()
            where hypot(p.x - pt.point.x, p.y - pt.point.y) <= grabRadius {
                draggingPoint = i
                pointDragMoved = false
                pressExtended = extend
                selectPoint(i, extend: extend)
                // Everything picked travels together, from where it stands now.
                dragPointStart = Dictionary(uniqueKeysWithValues: selectedPoints.compactMap { j in
                    vp.points.indices.contains(j) ? (j, vp.points[j].point) : nil
                })
                refreshHover(at: p)
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

        // The artboard's background reads as bare canvas: pressing on empty board
        // and dragging rubber-bands over the art, exactly like starting off-board.
        // The label above the corner stays the handle for the board itself.
        var hit = layerHit(p)
        if let l = hit, l.isArtboard, !artboards.contains(where: { $0.hit.contains(p) }) {
            hit = nil
        }
        guard let leaf = hit else {
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
        // ⇧⌘ drills past the group to the layer actually under the pointer — and
        // clicking AGAIN steps to the next layer down the stack, wrapping at the
        // bottom. That's how you reach the mug the laptop's frame is covering.
        let drill = event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift)
        if drill {
            var stack: [Layer] = []
            var seen = Set<String>()
            for d in composed.reversed() {
                if lockedDeep(d.layer.id) { continue }
                if let c = d.clip, !c.contains(p) { continue }
                let contains: Bool
                if let path = d.path { contains = path.contains(p) }
                else if d.text != nil || d.imageRef != nil {
                    contains = CGRect(origin: .zero, size: d.layer.frame.size)
                        .applying(d.transform).contains(p)
                } else { contains = false }
                guard contains else { continue }
                let t = selectionTarget(d.layer, drill: true)
                if seen.insert(t.id).inserted { stack.append(t) }
            }
            if !stack.isEmpty {
                var idx = 0
                if selected.count == 1, let cur = selected.first,
                   let i = stack.firstIndex(where: { $0.id == cur }) {
                    idx = (i + 1) % stack.count
                }
                let h = stack[idx]
                onSelect?(h.id, false)
                dragging = true
                onDragBegin?(h.id)
                var moving = selected
                moving.insert(h.id)
                snapTargets = page?.snapTargets(excluding: moving) ?? []
                return
            }
        }
        let h = selectionTarget(leaf, drill: drill)
        if !selected.contains(h.id) || extend { onSelect?(h.id, extend && !drill) }
        if !extend || drill {
            dragging = true
            onDragBegin?(h.id)
            // Gathered once here, not per frame: the set can't change during the drag.
            // Everything moving is excluded, including anything inside it — a group
            // that snapped to its own children could never be dragged anywhere.
            var moving = selected
            moving.insert(h.id)
            snapTargets = page?.snapTargets(excluding: moving) ?? []
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = pagePoint(convert(event.locationInWindow, from: nil))
        hoverPoint = p

        if tool == .pen, !penPoints.isEmpty {
            penCursor = p
            needsDisplay = true
        } else {
            // Show where a point would land while editing one. Double-click is not a
            // gesture anyone guesses at, so the path has to offer it.
            refreshHover(at: p)
            refreshInsertPreview()
        }

        // Last, because it reads the hover state the two calls above just settled.
        // Nothing is drawn in the rotate zone either, so out there the cursor is the
        // only clue it exists — without it you'd only find it by accident.
        updateCursor(at: p)
    }

    /// Works out which anchor or handle the pointer is over.
    private func refreshHover(at p: CGPoint?) {
        var point: Int?
        var handle: (index: Int, out: Bool)?
        if let i = draggingPoint {
            point = i                       // stays lit for the whole drag
        } else if let h = draggingHandle {
            handle = h
        } else if let p, let vp = editPath {
            // Handles before anchors, the same order a press resolves in — otherwise
            // where the two overlap the highlight would promise one thing and the click
            // do another.
            for (i, pt) in vp.points.enumerated() {
                if pt.hasCurveFrom, hypot(p.x - pt.curveFrom.x, p.y - pt.curveFrom.y) <= grabRadius {
                    handle = (i, true); break
                }
                if pt.hasCurveTo, hypot(p.x - pt.curveTo.x, p.y - pt.curveTo.y) <= grabRadius {
                    handle = (i, false); break
                }
            }
            if handle == nil {
                point = vp.points.firstIndex { hypot(p.x - $0.point.x, p.y - $0.point.y) <= grabRadius }
            }
        }
        let changed = point != hoveredPoint
            || handle?.index != hoveredHandle?.index
            || handle?.out != hoveredHandle?.out
        hoveredPoint = point
        hoveredHandle = handle
        if changed { needsDisplay = true }
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
        // AppKit resets the pointer whenever the rects are invalidated, so a tool cursor
        // has to be reinstated here or an unrelated redraw drops it back to an arrow.
        if tool == .pen {
            VectorCursors.pen(hoverPoint.map(penWouldClose) == true ? .close : .add).set()
            return
        }
        if editPath != nil {
            if let p = hoverPoint { updateCursor(at: p) }
            return
        }
        NSCursor.arrow.set()
    }

    /// Shift can be pressed without the pointer moving, and the preview has to follow.
    override func flagsChanged(with event: NSEvent) {
        refreshInsertPreview()
        if let p = hoverPoint { updateCursor(at: p) }
        super.flagsChanged(with: event)
    }

    /// Adds a point where the preview shows, for the keyboard path.
    @discardableResult
    private func insertPointAtPreview() -> Bool {
        guard let t = insertTarget, let made = editPath?.insertPoint(onSegment: t.segment, at: t.t)
        else { return false }
        // Inserting picks it, so the arrows are already aimed at the point just added.
        selectPoint(made, extend: false)
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
        selectedPoints = []
        lastTouchedPoint = nil
        commitEdit("Delete Point")
        refreshInsertPreview()
        needsDisplay = true
        return true
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        refreshHover(at: nil)
        refreshInsertPreview()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = pagePoint(convert(event.locationInWindow, from: nil))

        if let cd = cropDrag {
            let d = CGSize(width: p.x - cd.start.x, height: p.y - cd.start.y)
            cropDraft = Self.cropAdjusted(cd.rect, handle: cd.handle, by: d,
                                          within: cropFrame, minSide: 8 / scale)
            needsDisplay = true
            return
        }
        if eraseRectDrag != nil {
            eraseRectDrag!.current = p
            needsDisplay = true
            return
        }

        if draggingPoint != nil {
            let dx = p.x - dragAnchor.x, dy = p.y - dragAnchor.y
            for (i, start) in dragPointStart {
                editPath?.points[i].move(to: CGPoint(x: start.x + dx, y: start.y + dy))
            }
            pointDragMoved = true
            needsDisplay = true
            return
        }
        if let h = draggingHandle {
            editPath?.points[h.index].setHandle(out: h.out, to: p)
            pointDragMoved = true
            needsDisplay = true
            return
        }
        if var stroke = erasing {
            var pt = p
            // Shift rules the stroke straight, Photoshop-style — locked to the
            // drag's own heading from where the stroke began, snapped to 45°
            // steps so horizontals, verticals and diagonals land exactly.
            if event.modifierFlags.contains(.shift), let first = stroke.points.first {
                let anchor = first.applying(stroke.transform)
                let dx = p.x - anchor.x, dy = p.y - anchor.y
                if dx != 0 || dy != 0 {
                    let step = CGFloat.pi / 4
                    let heading = (atan2(dy, dx) / step).rounded() * step
                    let along = dx * cos(heading) + dy * sin(heading)
                    pt = CGPoint(x: anchor.x + along * cos(heading),
                                 y: anchor.y + along * sin(heading))
                }
            }
            brushAt = pt
            stroke.points.append(pt.applying(stroke.transform.inverted()))
            erasing = stroke
            needsDisplay = true
            return
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
            // The padlock decides: locked layers resize proportionally, and shift
            // inverts whichever mode the selection is in — so an unlocked layer
            // constrains while shift is down, a locked one stretches free.
            let locked = selected.allSatisfy { page?.layer($0)?.constrainProportions ?? true }
            if locked != event.modifierFlags.contains(.shift) {
                if abs(startW) > 0.001, abs(startH) > 0.001 {
                    let s = max(abs(sx), abs(sy))
                    sx = s * (sx < 0 ? -1 : 1); sy = s * (sy < 0 ? -1 : 1)
                } else if abs(startW) > 0.001 {
                    sy = abs(sx)               // edge drag: the other axis follows
                } else if abs(startH) > 0.001 {
                    sx = abs(sy)
                }
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
        var offset = CGSize(width: p.x - dragAnchor.x, height: p.y - dragAnchor.y)

        // Holding ⌘ turns snapping off for the moment. There is always a position
        // snapping won't let you reach, and the answer to that has to be a key you
        // hold rather than a preference you go and find.
        if event.modifierFlags.contains(.command) || snapTargets.isEmpty {
            snapGuides = []
        } else if let bounds = selectionBounds {
            let proposed = bounds.offsetBy(dx: offset.width, dy: offset.height)
            // Tolerance in screen pixels, converted: fixed page units would be
            // unusably grabby zoomed out and unreachable zoomed in.
            let result = Snapping.snap(proposed, to: snapTargets,
                                       tolerance: 7 / max(0.01, currentScale))
            offset.width += result.adjustment.width
            offset.height += result.adjustment.height
            snapGuides = result.guides
        }

        dragOffset = offset
        needsDisplay = true
    }

    /// Moves or resizes the crop window, clamped inside the layer.
    private static func cropAdjusted(_ r0: CGRect, handle: Handle?, by d: CGSize,
                                     within bounds: CGRect, minSide: CGFloat) -> CGRect {
        var r = r0
        switch handle {
        case nil:
            r.origin.x += d.width
            r.origin.y += d.height
            r.origin.x = min(max(r.origin.x, bounds.minX), bounds.maxX - r.width)
            r.origin.y = min(max(r.origin.y, bounds.minY), bounds.maxY - r.height)
            return r
        case .nw: r.origin.x += d.width; r.size.width -= d.width
                  r.origin.y += d.height; r.size.height -= d.height
        case .n:  r.origin.y += d.height; r.size.height -= d.height
        case .ne: r.size.width += d.width
                  r.origin.y += d.height; r.size.height -= d.height
        case .e:  r.size.width += d.width
        case .se: r.size.width += d.width; r.size.height += d.height
        case .s:  r.size.height += d.height
        case .sw: r.origin.x += d.width; r.size.width -= d.width
                  r.size.height += d.height
        case .w:  r.origin.x += d.width; r.size.width -= d.width
        }
        // A dragged-through edge flips; clamp instead, then keep it in the layer.
        if r.width < minSide { if handle == .nw || handle == .sw || handle == .w { r.origin.x = r.maxX - minSide }; r.size.width = minSide }
        if r.height < minSide { if handle == .nw || handle == .ne || handle == .n { r.origin.y = r.maxY - minSide }; r.size.height = minSide }
        return r.intersection(bounds)
    }

    private func cropHandleHit(_ p: CGPoint) -> Handle? {
        let grab = 8 / scale
        for h in [Handle.nw, .n, .ne, .e, .se, .s, .sw, .w] {
            let c = handlePoint(h, in: cropDraft)
            if abs(p.x - c.x) <= grab, abs(p.y - c.y) <= grab { return h }
        }
        return nil
    }

    override func mouseUp(with event: NSEvent) {
        if cropDrag != nil { cropDrag = nil; return }
        if let er = eraseRectDrag {
            eraseRectDrag = nil
            let pageRect = CGRect(x: min(er.start.x, er.current.x),
                                  y: min(er.start.y, er.current.y),
                                  width: abs(er.current.x - er.start.x),
                                  height: abs(er.current.y - er.start.y))
            let local = pageRect.applying(er.t.inverted())
            if local.width > 1, local.height > 1 {
                // The same drag serves two tools: erase cuts the box out itself,
                // remove sends it off to be understood first.
                if tool == .remove { onRemoveRect?(er.id, local) } else { onEraseRect?(er.id, local) }
            }
            needsDisplay = true
            return
        }
        defer { needsDisplay = true }   // a click that commits nothing still changes what's drawn
        // A press that never went anywhere is a click, not an edit. Committing it anyway
        // put an empty step on the undo stack — and the first half of every double-click
        // is exactly that press, so curving a point would take two undos to take back.
        if let i = draggingPoint {
            draggingPoint = nil
            if pointDragMoved {
                commitEdit(dragPointStart.count > 1 ? "Move Points" : "Move Point")
            } else if !pressExtended {
                // The press left the set alone so a drag could take everything with it.
                // It didn't drag, so it was a click, and a click means just this one.
                selectedPoints = [i]
                lastTouchedPoint = i
            }
            dragPointStart = [:]
            refreshHover(at: hoverPoint)
            return
        }
        if draggingHandle != nil {
            draggingHandle = nil
            if pointDragMoved { commitEdit("Adjust Handle") }
            refreshHover(at: hoverPoint)
            return
        }
        if let stroke = erasing {
            erasing = nil
            onErase?(stroke.layer, stroke.points)
            return
        }
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
        snapGuides = []
        onDragEnd?(o)
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 36:   // return — finish an open path, or step into the selected path
            if let id = croppingID {
                // Commit the crop as a unit rect of the layer's frame.
                let u = CGRect(x: (cropDraft.minX - cropFrame.minX) / cropFrame.width,
                               y: (cropDraft.minY - cropFrame.minY) / cropFrame.height,
                               width: cropDraft.width / cropFrame.width,
                               height: cropDraft.height / cropFrame.height)
                onCommitCrop?(id, u)
                return
            }
            if tool == .pen { finishPen(close: false); onExitTool?(); return }
            // Sketch's Enter: point editing on whatever is selected. This is also the
            // reliable way into a combined shape's member picked from the layer list —
            // no hunting for a spot the hit-test can reach.
            if tool == .select, editingLayerID == nil, selected.count == 1,
               let id = selected.first, let page,
               let l = page.layer(id), case .path = l.kind {
                if let group = page.ancestors(of: id).last,
                   page.layer(group)?.isContainer == true { enteredGroup = group }
                editingLayerID = id
                return
            }
        case 53:   // escape — abandon
            // Escape drops whatever is half-drawn *and* hands the cursor back. Staying
            // in the pen after cancelling was the trap: nothing on screen changed, so
            // the tool read as stuck.
            if croppingID != nil { onCancelCrop?(); return }
            if tool == .pen {
                penPoints = []; penCursor = nil; needsDisplay = true
                onExitTool?()
                return
            }
            if tool != .select { onExitTool?(); return }
            // One step at a time on the way out: drop the picked points, then the mode.
            if !selectedPoints.isEmpty { selectedPoints = []; lastTouchedPoint = nil; return }
            if editingLayerID != nil { editingLayerID = nil; return }
            if enteredGroup != nil { enteredGroup = nil; return }
        case 51, 117:  // delete
            // Picked points go first; otherwise the layer selection goes.
            if removeSelectedPoints() { return }
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
        // Arrows move the picked points when there are any, and the layer otherwise —
        // in point editing the layer is the thing you're least likely to have meant.
        case 123: if !nudgePoints(-step, 0) { onNudge?(-step, 0) }   // left
        case 124: if !nudgePoints(step, 0) { onNudge?(step, 0) }     // right
        case 125: if !nudgePoints(0, step) { onNudge?(0, step) }     // down (canvas is y-down)
        case 126: if !nudgePoints(0, -step) { onNudge?(0, -step) }   // up
        default: super.keyDown(with: event)
        }
    }
}


extension PageCanvas: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ n: Notification) {
        // Fires for Enter and for clicking away — both mean "keep what I typed".
        endLabelEdit(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
        endLabelEdit(commit: false)   // Escape: the edit never happened
        return true
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
    let cropping: String?

    func makeNSView(context: Context) -> PageCanvas {
        let canvas = PageCanvas()
        wire(canvas)
        context.coordinator.canvas = canvas
        return canvas
    }

    func updateNSView(_ canvas: PageCanvas, context: Context) {
        let pageChanged = context.coordinator.lastPageToken != pageToken
        canvas.images = images
        canvas.page = page
        canvas.selected = selection
        canvas.pageToken = pageToken
        canvas.revision = revision
        canvas.tool = tool
        canvas.croppingID = cropping
        wire(canvas)
        if let req = pointMode, context.coordinator.lastPointModeSerial != req.serial {
            context.coordinator.lastPointModeSerial = req.serial
            canvas.applyPointMode(req.mode)
        }
        if context.coordinator.lastZoomSerial != zoom.serial {
            context.coordinator.lastZoomSerial = zoom.serial
            apply(zoom.intent, canvas: canvas)
        }
        if pageChanged, let page {
            context.coordinator.lastPageToken = pageToken
            // Fit on arrival: these pages range from 180pt to 15,000pt wide, so a
            // fixed default zoom would be useless most of the time. Once the view has
            // a size — on the very first pass through SwiftUI it hasn't.
            _ = page
            if canvas.bounds.width > 1 {
                canvas.fit(canvas.contentRectInView)
            } else {
                DispatchQueue.main.async { canvas.fit(canvas.contentRectInView) }
            }
        }
    }

    /// Carries out a zoom request. The canvas owns its own magnification now, so
    /// there is no scroll view to ask and no layout to wait for.
    private func apply(_ intent: ZoomIntent, canvas: PageCanvas) {
        let centre = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        switch intent {
        case .zoomIn:     canvas.zoom(to: canvas.scale * 1.25, around: canvas.pageCentre)
        case .zoomOut:    canvas.zoom(to: canvas.scale / 1.25, around: canvas.pageCentre)
        case .actualSize: canvas.zoom(to: 1, around: canvas.pageCentre)
        case .fit:        canvas.fit(canvas.contentRectInView)
        case .toSelection:
            // Falls back to fit rather than doing nothing, which would read as broken.
            let rect = canvas.selectionRectInView
            canvas.fit(rect.isEmpty ? canvas.contentRectInView : rect)
        }
        _ = centre
    }

    private func wire(_ canvas: PageCanvas) {
        canvas.onSelect = { id, extend in store.select(id, extend: extend) }
        canvas.onRenameLayer = { id, name in store.rename(id, to: name) }
        canvas.onEditTextContent = { id, s in
            store.editText(id, "Edit Text") { $0.string = s }
        }
        canvas.onToggleLock = { store.toggleLock() }
        canvas.onToggleHide = { store.toggleLockOrHide(hide: true) }
        canvas.onCommitCrop = { id, unit in store.applyCrop(id, unit: unit) }
        canvas.onCancelCrop = { store.croppingID = nil }
        canvas.onEraseRect = { id, r in store.eraseRect(id, rect: r) }
        canvas.onRemoveRect = { id, r in store.removeRegion(id, rect: r) }
        canvas.onMarquee = { rect, extend in
            guard let p = store.page else { return }
            store.selectAll(in: rect, on: p, extend: extend)
        }
        canvas.onDragBegin = { id in store.beginDrag(id) }
        canvas.onDragEnd = { offset in store.endDrag(offset: offset) }
        canvas.onNudge = { dx, dy in store.nudge(dx: dx, dy: dy) }
        canvas.onDelete = { store.deleteSelection() }
        canvas.onZoom = { store.zoom($0) }
        canvas.onErase = { id, points in store.erase(id, points: points) }
        canvas.eraseRadius = CGFloat(store.eraseRadius)
        canvas.eraseSoftness = CGFloat(store.eraseSoftness)
        canvas.onPointSelected = { i, m in
            store.editingPoint = i.flatMap { idx in m.map { DocumentStore.EditingPoint(index: idx, mode: $0) } }
        }
        canvas.onResizeBegin = { store.beginResize() }
        canvas.onResizeEnd = { scale, anchor in store.endResize(scale: scale, anchor: anchor) }
        canvas.onRotateBegin = { store.beginRotate() }
        canvas.onRotateEnd = { degrees, centre in store.endRotate(degrees: degrees, centre: centre) }
        canvas.onDrawPath = { vp in store.commitDrawnPath(vp) }
        canvas.onEditPath = { vp, id, name in store.commitEditedPath(vp, layerID: id, actionName: name) }
        canvas.onExitTool = { store.tool = .select }
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
