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

/// Where a dragged layer would land.
///
/// Three outcomes from one gesture, decided by where in the row you are: the top and
/// bottom thirds reorder, the middle third drops *into* a container. That middle band
/// is what makes "drag a photo into an artboard" a different act from "drag it above
/// the artboard", which is the distinction the whole feature rests on.
public enum DropSpot: Equatable, Sendable {
    case above(String)
    case below(String)
    case inside(String)
}


extension DropSpot {
    /// Resolves to a parent and an index in that parent's children.
    ///
    /// Dropping below an expanded container means "first thing inside it", not "after
    /// the whole subtree" — otherwise the obvious gesture puts the layer somewhere it
    /// visually isn't.
    public func resolve(in page: Page, expanded: Set<String>) -> (parent: String?, index: Int)? {
        switch self {
        case .inside(let id):
            return (id, page.children(of: id).count)

        case .above(let id), .below(let id):
            let below: Bool
            if case .below = self { below = true } else { below = false }
            if below, let l = page.layer(id), l.isContainer, expanded.contains(id) {
                return (id, 0)
            }
            let parent = page.ancestors(of: id).last
            let siblings = page.children(of: parent).map(\.id)
            guard let i = siblings.firstIndex(of: id) else { return nil }
            return (parent, below ? i + 1 : i)
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


extension DropSpot {
    public var target: String {
        switch self {
        case .above(let id), .below(let id), .inside(let id): return id
        }
    }
}
