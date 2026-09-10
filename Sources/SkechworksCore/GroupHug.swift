import CoreGraphics
import Foundation

// A group's frame is the box around what is in it. Sketch keeps that true on
// every edit; here the frame was set once and then left, and a group that lost
// a child or was pasted out of an SVG's viewBox kept the old box. The panel
// then said 500 wide for a drawing 473 wide, and typing 500 into W made the
// group's empty margin 500 wide with the drawing still short of the artboard.

extension Layer {

    /// True for a group whose frame is free to follow its children: a plain
    /// group, not turned, flipped or leaned. Turning happens about the frame's
    /// centre, so moving that frame would move the picture.
    public var hugsChildren: Bool {
        guard case .group = kind, !isArtboard else { return false }
        return rotation == 0 && !flipH && !flipV && skewX == 0 && skewY == 0
    }

    /// The box around the children, in the group's own space. Each child is
    /// measured the way it paints (turned, if it is turned), and hidden ones
    /// count: hiding a layer should not shift the group it sits in.
    public var childrenBox: CGRect? {
        guard case .group(let kids) = kind, !kids.isEmpty else { return nil }
        var box = CGRect.null
        for k in kids {
            box = box.union(CGRect(origin: .zero, size: k.frame.size).applying(Compose.transform(k)))
        }
        return box.isNull ? nil : box
    }

    /// Pulls the frame in around the children. No child moves on the page:
    /// what the frame gains in origin the children lose in theirs.
    public mutating func hugChildren() {
        guard hugsChildren, case .group(var kids) = kind, let box = childrenBox else { return }
        // A hundredth of a point is noise, and hugging on noise would nudge
        // the children by it on every edit.
        let stale = abs(box.minX) > 0.01 || abs(box.minY) > 0.01
            || abs(box.width - frame.width) > 0.01 || abs(box.height - frame.height) > 0.01
        guard stale else { return }
        for i in kids.indices {
            kids[i].frame.origin.x -= box.minX
            kids[i].frame.origin.y -= box.minY
        }
        kind = .group(kids)
        frame = CGRect(x: frame.minX + box.minX, y: frame.minY + box.minY,
                       width: box.width, height: box.height)
    }
}

extension Page {

    /// Every group's frame pulled in around what it holds, innermost first, so
    /// a group of groups measures the boxes its children ended up with.
    public func huggingGroups() -> Page {
        func hug(_ layers: [Layer]) -> [Layer] {
            layers.map { layer in
                var l = layer
                switch l.kind {
                case .group(let kids):
                    l.kind = .group(hug(kids))
                    l.hugChildren()
                case .shapeGroup(let kids, let winding):
                    l.kind = .shapeGroup(hug(kids), winding)
                default: break
                }
                return l
            }
        }
        var out = self
        out.layers = hug(layers)
        return out
    }
}
