import CoreGraphics
import Foundation

// Moving layers around the tree — reordering, and dragging something into or out of
// an artboard or group.
//
// The whole point of dragging a photo into an artboard is that it becomes a child and
// gets clipped to the artboard's edge. That only works if the move is a real change of
// parent, not a change of drawing order.

extension Page {

    /// Absolute position of a layer's origin, in page coordinates.
    ///
    /// Child frames are relative to their container, so this is the running sum down
    /// the tree. Needed on both sides of a move: without it, dragging a photo into an
    /// artboard would leave its origin unchanged and jump it by the artboard's offset.
    public func absoluteOrigin(of id: String) -> CGPoint? {
        guard let l = layer(id) else { return nil }
        var p = l.frame.origin
        for a in ancestors(of: id) {
            guard let anc = layer(a) else { continue }
            p.x += anc.frame.minX
            p.y += anc.frame.minY
        }
        return p
    }

    /// Whether `id` is `ancestor` or sits inside it.
    public func isInside(_ id: String, _ ancestor: String) -> Bool {
        id == ancestor || ancestors(of: id).contains(ancestor)
    }

    /// Moves layers into a new parent (nil for the page itself) at a given index.
    ///
    /// Layers keep their place on the canvas: frames are converted out of the old
    /// container's coordinates and into the new one's.
    ///
    /// Returns false when the move can't be made — dropping a group inside itself is
    /// the one that matters, since it would detach that whole subtree from the document.
    @discardableResult
    public mutating func reparent(_ ids: [String], into newParent: String?, at index: Int) -> Bool {
        let moving = ids.filter { layer($0) != nil }
        guard !moving.isEmpty else { return false }

        if let newParent {
            guard layer(newParent) != nil else { return false }
            // Into itself or its own descendant: refuse.
            for id in moving where isInside(newParent, id) { return false }
            // Only containers can take children.
            switch layer(newParent)!.kind {
            case .group, .shapeGroup: break
            default: return false
            }
        }

        // Where everything sits now, before anything moves.
        let origins = Dictionary(uniqueKeysWithValues: moving.compactMap { id in
            absoluteOrigin(of: id).map { (id, $0) }
        })

        // Document order, so a multi-layer drag keeps its relative stacking.
        let ordered = find(LayerQuery()).filter { moving.contains($0) }

        // Note the target's neighbour before removing anything: indices shift.
        let siblingsBefore = children(of: newParent).map(\.id)
        let anchorID = index < siblingsBefore.count ? siblingsBefore[index] : nil
        let anchorStillThere = anchorID.map { !moving.contains($0) } ?? false

        var lifted: [Layer] = []
        for id in ordered {
            if let removed = removeLayer(id) { lifted.append(removed.layer) }
        }
        guard !lifted.isEmpty else { return false }

        let parentOrigin = newParent.flatMap { absoluteOrigin(of: $0) } ?? .zero
        for i in lifted.indices {
            if let was = origins[lifted[i].id] {
                lifted[i].frame.origin = CGPoint(x: was.x - parentOrigin.x, y: was.y - parentOrigin.y)
            }
        }

        // Re-find the drop position: removing layers above it shifted everything.
        let siblingsNow = children(of: newParent).map(\.id)
        var at = siblingsNow.count
        if anchorStillThere, let anchorID, let found = siblingsNow.firstIndex(of: anchorID) {
            at = found
        } else if anchorID == nil {
            at = siblingsNow.count
        } else {
            at = min(index, siblingsNow.count)
        }

        for (offset, l) in lifted.enumerated() {
            insertLayer(l, parent: newParent, index: at + offset)
        }
        return true
    }

    /// Where a layer's container sits, in page coordinates.
    public func parentOrigin(of id: String) -> CGPoint {
        var o = CGPoint.zero
        for a in ancestors(of: id) {
            guard let anc = layer(a) else { continue }
            o.x += anc.frame.minX
            o.y += anc.frame.minY
        }
        return o
    }

    /// Scales layers about a point given in PAGE coordinates.
    ///
    /// Frames are stored relative to their container, and the resize anchor comes from
    /// the selection on screen, which is absolute. Applying one to the other directly
    /// works only for layers sitting at the top level — anything inside a group or an
    /// artboard gets thrown by its container's offset, which reads as the object
    /// re-centring itself the moment you let go of the handle.
    ///
    /// `startFrames` are the frames as they were when the drag began, so a gesture
    /// stays exact instead of accumulating rounding on every mouse move.
    public mutating func scale(_ ids: [String], about anchor: CGPoint, by scale: CGSize,
                               from startFrames: [String: CGRect]) {
        for id in ids {
            guard let start = startFrames[id] else { continue }
            let parent = parentOrigin(of: id)
            let absolute = CGPoint(x: parent.x + start.minX, y: parent.y + start.minY)
            let moved = CGPoint(x: anchor.x + (absolute.x - anchor.x) * scale.width,
                                y: anchor.y + (absolute.y - anchor.y) * scale.height)
            updateLayer(id) { l in
                l.frame.origin = CGPoint(x: moved.x - parent.x, y: moved.y - parent.y)
                l.resize(to: CGSize(width: max(1, start.width * scale.width),
                                    height: max(1, start.height * scale.height)))
            }
        }
    }

    /// Rotates layers by `degrees` about a point given in PAGE coordinates.
    ///
    /// A layer's own rotation turns it about its centre, so one layer rotating about
    /// itself only needs the angle. Several layers turning together also have to swing
    /// around the shared centre, or they'd each spin in place and the arrangement would
    /// come apart.
    ///
    /// `startAngles` and `startFrames` are from when the drag began, so the gesture
    /// stays exact instead of accumulating.
    public mutating func rotate(_ ids: [String], about anchor: CGPoint, by degrees: CGFloat,
                                startAngles: [String: CGFloat], startFrames: [String: CGRect]) {
        let radians = -degrees * .pi / 180        // page space is y-down
        for id in ids {
            guard let startAngle = startAngles[id], let start = startFrames[id] else { continue }
            let parent = parentOrigin(of: id)
            let centre = CGPoint(x: parent.x + start.midX, y: parent.y + start.midY)
            let dx = centre.x - anchor.x, dy = centre.y - anchor.y
            let swung = CGPoint(x: anchor.x + dx * cos(radians) - dy * sin(radians),
                                y: anchor.y + dx * sin(radians) + dy * cos(radians))
            updateLayer(id) { l in
                l.rotation = (startAngle + degrees).truncatingRemainder(dividingBy: 360)
                l.frame.origin = CGPoint(x: swung.x - parent.x - start.width / 2,
                                         y: swung.y - parent.y - start.height / 2)
            }
        }
    }

    /// Direct children of a container, or the page's own layers.
    public func children(of parent: String?) -> [Layer] {
        guard let parent else { return layers }
        guard let l = layer(parent) else { return [] }
        switch l.kind {
        case .group(let k), .shapeGroup(let k, _): return k
        default: return []
        }
    }
}

extension Layer {
    /// Can this take children? Artboards and groups can; a path or a photo cannot.
    public var isContainer: Bool {
        switch kind {
        case .group, .shapeGroup: return true
        default: return false
        }
    }
}

public enum LayerOrder {
    /// Converts a row position in the layer list into an index in the model.
    ///
    /// The list is drawn top-first — the front-most layer at the top — and layers are
    /// stored bottom-first. AppKit hands back "insert before display row N"; the model
    /// wants an index counted from the other end.
    public static func modelIndex(displayIndex: Int, childCount: Int) -> Int {
        max(0, min(childCount, childCount - displayIndex))
    }
}

public enum CanvasExtent {
    /// How far the canvas runs past the artwork, in page units.
    ///
    /// Sketch and Figma give you a canvas that doesn't end — you push the page aside
    /// and work in the space next to it. Not literally infinite here: a document a few
    /// times the size of the artwork is indistinguishable from infinite in use and
    /// keeps the coordinates ordinary.
    ///
    /// Proportional, with a floor. A fixed margin would feel generous around an icon
    /// and cramped around a 15,000-point page of coins.
    public static func margin(for content: CGSize) -> CGFloat {
        max(4000, max(content.width, content.height) * 2)
    }
}

/// The small overview that appears when you've scrolled the artwork off screen.
///
/// An infinite canvas has one failure mode: pan far enough and there is nothing to
/// look at and no edge to tell you which way back. Sketch answers it with a miniature
/// of the page in the corner, showing where the artwork is and where you are. It only
/// appears when it's needed, which is the part that makes it useful rather than
/// clutter.
public enum Minimap {
    /// Shown only when no part of the artwork is on screen.
    public static func isNeeded(content: CGRect, visible: CGRect) -> Bool {
        guard content.width > 0, content.height > 0 else { return false }
        return !content.intersects(visible)
    }

    /// Maps page coordinates into a card of `size`, fitting the artwork and the
    /// viewport together so both are always visible — a minimap that can't show you
    /// where you are is decoration.
    public static func transform(content: CGRect, visible: CGRect,
                                 into size: CGSize, padding: CGFloat = 10) -> CGAffineTransform {
        let world = content.union(visible)
        guard world.width > 0, world.height > 0 else { return .identity }
        let usable = CGSize(width: max(1, size.width - padding * 2),
                            height: max(1, size.height - padding * 2))
        let scale = min(usable.width / world.width, usable.height / world.height)
        // Centre whatever's left over, so the card doesn't look weighted to a corner.
        let dx = padding + (usable.width - world.width * scale) / 2
        let dy = padding + (usable.height - world.height * scale) / 2
        return CGAffineTransform(translationX: dx, y: dy)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -world.minX, y: -world.minY)
    }
}

extension Page {

    /// Combines layers into one shape.
    ///
    /// The BOTTOM layer is the base and everything above it is applied with `op`.
    /// Layer order, not click order — which is what Sketch and Figma both do, and the
    /// reason Subtract changes result when you reorder the layers but Union doesn't.
    ///
    /// Non-destructive: the originals become children of the combined shape and keep
    /// their own geometry, so the operation can be changed or undone by ungrouping
    /// rather than only by undo.
    @discardableResult
    public mutating func combine(_ ids: [String], op: BooleanOp, named name: String? = nil) -> String? {
        // Document order throughout: it decides the stacking AND which shape is the
        // base, so a Subtract can be corrected by moving a layer rather than by
        // undoing and re-selecting in a different sequence.
        let ordered = find(LayerQuery()).filter { ids.contains($0) }
        guard ordered.count >= 2 else { return nil }

        // One parent only. Combining across two artboards has no sensible frame.
        let parents = Set(ordered.map { ancestors(of: $0).last })
        guard parents.count == 1, let parent = parents.first else { return nil }

        // Their extent in the parent's space becomes the new shape's frame.
        var box = CGRect.null
        for id in ordered {
            guard let l = layer(id) else { continue }
            box = box.union(l.frame)
        }
        guard !box.isNull, box.width > 0, box.height > 0 else { return nil }

        var members: [Layer] = []
        for (i, id) in ordered.enumerated() {
            guard var l = layer(id) else { continue }
            // Children are positioned relative to the combined shape.
            l.frame.origin = CGPoint(x: l.frame.minX - box.minX, y: l.frame.minY - box.minY)
            // The base carries no operation; it's what the others are applied to.
            l.booleanOp = i == 0 ? .none : op
            members.append(l)
        }
        for id in ordered { removeLayer(id) }

        var made = Layer(kind: .shapeGroup(members, .nonZero))
        made.name = name ?? Page.combinedName(op)
        made.frame = box
        // The result takes the base's appearance, the way it does in Sketch — the
        // shapes are one object now and only one fill can win.
        if let first = members.first {
            made.style.fills = first.style.fills
            made.style.borders = first.style.borders
            made.style.shadows = first.style.shadows
        }

        // Back where the topmost of them was, so the stack doesn't change.
        let siblings = children(of: parent).count
        insertLayer(made, parent: parent, index: siblings)
        return made.id
    }

    public static func combinedName(_ op: BooleanOp) -> String {
        switch op {
        case .union: return "Union"
        case .subtract: return "Subtract"
        case .intersect: return "Intersect"
        case .difference: return "Difference"
        case .none: return "Combined"
        }
    }

    /// Replaces a combined shape with the single path it draws.
    ///
    /// The opposite trade to combining: the children go, and with them the ability to
    /// change your mind, in exchange for one ordinary path that behaves like any other
    /// and exports as one outline.
    @discardableResult
    public mutating func flattenShape(_ id: String) -> Bool {
        guard let l = layer(id) else { return false }
        switch l.kind {
        case .shapeGroup, .group: break
        default: return false
        }
        guard let path = Compose.resolvedPath(l) else { return false }
        updateLayer(id) { layer in
            layer.kind = .path(path, closed: true)
            layer.curveModes = []
        }
        return true
    }

    /// Changes how a child of a combined shape is applied to the ones before it.
    public mutating func setBooleanOp(_ id: String, to op: BooleanOp) {
        updateLayer(id) { $0.booleanOp = op }
    }
}
