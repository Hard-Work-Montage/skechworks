import CoreGraphics
import Foundation

// Z-order, alignment, distribution, grouping.
//
// All of these operate on SIBLINGS: layers only stack against, align to, or group
// with things in the same parent. Operating across parents would produce results that
// look arbitrary — a layer "in front of" something in a different group means nothing.
// So a mixed selection is bucketed by parent and each bucket handled on its own.

public enum AlignEdge: Sendable {
    case left, horizontalCentre, right, top, verticalMiddle, bottom
}

public enum Axis: Sendable { case horizontal, vertical }

extension Page {

    // MARK: - Z-order
    //
    // layers[0] is BACK-most, matching Sketch's file order — so "bring forward" moves
    // a layer LATER in the array.

    public mutating func bringForward(_ ids: Set<String>) { shift(ids, by: +1) }
    public mutating func sendBackward(_ ids: Set<String>) { shift(ids, by: -1) }

    public mutating func bringToFront(_ ids: Set<String>) { toEdge(ids, front: true) }
    public mutating func sendToBack(_ ids: Set<String>) { toEdge(ids, front: false) }

    private mutating func shift(_ ids: Set<String>, by delta: Int) {
        forEachSiblingGroup(ids) { siblings, picked in
            // Walk from the end when moving forward so two adjacent selected layers
            // don't swap into each other and cancel out.
            let order = delta > 0 ? picked.sorted(by: >) : picked.sorted()
            for i in order {
                let target = i + delta
                guard siblings.indices.contains(target) else { continue }
                if picked.contains(target) { continue }   // blocked by another selected layer
                siblings.swapAt(i, target)
            }
        }
    }

    private mutating func toEdge(_ ids: Set<String>, front: Bool) {
        forEachSiblingGroup(ids) { siblings, picked in
            let moving = picked.sorted().map { siblings[$0] }
            for i in picked.sorted(by: >) { siblings.remove(at: i) }
            if front { siblings.append(contentsOf: moving) }
            else { siblings.insert(contentsOf: moving, at: 0) }
        }
    }

    // MARK: - Align & distribute

    public mutating func align(_ ids: Set<String>, to edge: AlignEdge) {
        forEachSiblingGroup(ids) { siblings, picked in
            guard picked.count > 1 else { return }
            let frames = picked.map { siblings[$0].frame }
            let bounds = frames.reduce(CGRect.null) { $0.union($1) }
            for i in picked {
                var f = siblings[i].frame
                switch edge {
                case .left:             f.origin.x = bounds.minX
                case .horizontalCentre: f.origin.x = bounds.midX - f.width / 2
                case .right:            f.origin.x = bounds.maxX - f.width
                case .top:              f.origin.y = bounds.minY
                case .verticalMiddle:   f.origin.y = bounds.midY - f.height / 2
                case .bottom:           f.origin.y = bounds.maxY - f.height
                }
                siblings[i].frame = f
            }
        }
    }

    /// Even gaps between layers, leaving the two outermost where they are.
    public mutating func distribute(_ ids: Set<String>, along axis: Axis) {
        forEachSiblingGroup(ids) { siblings, picked in
            guard picked.count > 2 else { return }
            let sorted = picked.sorted {
                axis == .horizontal ? siblings[$0].frame.minX < siblings[$1].frame.minX
                                    : siblings[$0].frame.minY < siblings[$1].frame.minY
            }
            let frames = sorted.map { siblings[$0].frame }
            let span = axis == .horizontal
                ? frames.last!.maxX - frames.first!.minX
                : frames.last!.maxY - frames.first!.minY
            let used = frames.reduce(0) { $0 + (axis == .horizontal ? $1.width : $1.height) }
            let gap = (span - used) / CGFloat(frames.count - 1)

            var cursor = axis == .horizontal ? frames.first!.minX : frames.first!.minY
            for i in sorted {
                if axis == .horizontal {
                    siblings[i].frame.origin.x = cursor
                    cursor += siblings[i].frame.width + gap
                } else {
                    siblings[i].frame.origin.y = cursor
                    cursor += siblings[i].frame.height + gap
                }
            }
        }
    }

    // MARK: - Group & ungroup

    /// Wraps a selection in a new group, returning its id.
    ///
    /// Children are re-originned relative to the group's frame, since a layer's frame
    /// is always relative to its parent.
    @discardableResult
    public mutating func group(_ ids: Set<String>, named name: String = "Group") -> String? {
        var madeID: String?
        forEachSiblingGroup(ids) { siblings, picked in
            guard picked.count >= 1, madeID == nil else { return }
            let sorted = picked.sorted()
            let members = sorted.map { siblings[$0] }
            let bounds = members.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            guard !bounds.isNull else { return }

            var g = Layer(kind: .group(members.map { child in
                var c = child
                c.frame.origin = CGPoint(x: c.frame.minX - bounds.minX,
                                         y: c.frame.minY - bounds.minY)
                return c
            }))
            g.name = name
            g.frame = bounds
            // Lands where the topmost member was, so grouping doesn't restack anything.
            let insertAt = sorted.last! - (sorted.count - 1)
            for i in sorted.reversed() { siblings.remove(at: i) }
            siblings.insert(g, at: min(max(0, insertAt), siblings.count))
            madeID = g.id
        }
        return madeID
    }

    /// Replaces a group with its children, promoting them into the parent's space.
    @discardableResult
    public mutating func ungroup(_ id: String) -> [String] {
        var freed: [String] = []
        func walk(_ ls: inout [Layer]) -> Bool {
            for i in ls.indices {
                if ls[i].id == id {
                    // An empty group ungroups to nothing: the shell goes. Skipping
                    // them left husks that "ungroup everything" could never clear.
                    guard case .group(let kids) = ls[i].kind else { return true }
                    let origin = ls[i].frame.origin
                    let promoted = kids.map { child -> Layer in
                        var c = child
                        c.frame.origin = CGPoint(x: c.frame.minX + origin.x,
                                                 y: c.frame.minY + origin.y)
                        return c
                    }
                    freed = promoted.map(\.id)
                    ls.replaceSubrange(i...i, with: promoted)
                    return true
                }
                switch ls[i].kind {
                case .group(var k):
                    if walk(&k) { ls[i].kind = .group(k); return true }
                case .shapeGroup(var k, let rule):
                    if walk(&k) { ls[i].kind = .shapeGroup(k, rule); return true }
                default: continue
                }
            }
            return false
        }
        _ = walk(&layers)
        return freed
    }

    // MARK: - Sibling bucketing

    /// Runs `body` once per parent that contains any of `ids`, handing it that
    /// parent's child array and the indices of the selected members.
    private mutating func forEachSiblingGroup(
        _ ids: Set<String>,
        _ body: (inout [Layer], Set<Int>) -> Void
    ) {
        func visit(_ ls: inout [Layer]) {
            let picked = Set(ls.indices.filter { ids.contains(ls[$0].id) })
            if !picked.isEmpty { body(&ls, picked) }
            for i in ls.indices {
                switch ls[i].kind {
                case .group(var k): visit(&k); ls[i].kind = .group(k)
                case .shapeGroup(var k, let rule): visit(&k); ls[i].kind = .shapeGroup(k, rule)
                default: continue
                }
            }
        }
        visit(&layers)
    }
}
