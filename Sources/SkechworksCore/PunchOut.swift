import CoreGraphics
import Foundation

/// Path ▸ Punch Out: one shape from a stack of dark and light ones.
///
/// A traced black and white drawing comes back as solid shapes in painting
/// order: the disc, the letters on top of it, the counters of the letters on
/// top of those. To get one outline with holes where the light shapes were,
/// you had to select the disc and each letter and Subtract, then the counters
/// and Union, and so on up the stack. That is a fold over the painting order
/// where every dark shape adds and every light shape cuts, and nothing about
/// it needs a person to decide which is which.
///
/// The result is a combined shape, the same kind Subtract makes: the pieces
/// are still inside it with an operation each, so a letter can still be moved
/// and the holes follow. Ungroup gives the pieces back; Flatten Path bakes it.
public enum PunchOut {
    public enum Outcome: Equatable {
        /// The combined shape's id, how many dark pieces it kept and how many
        /// light ones cut holes.
        case made(id: String, inks: Int, holes: Int)
        case refused(String)
    }

    /// Darker than mid grey is ink. Rec. 709 luma, which is what a screen
    /// shows and close enough to what a trace produced: its fills are pure
    /// black and pure white and never come near the line.
    static func isInk(_ color: Color) -> Bool {
        0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b < 0.5
    }

    /// The colour a layer paints with, or nil when it paints nothing.
    static func paintColor(_ l: Layer) -> Color? {
        for f in l.style.fills where f.opacity > 0 {
            switch f.paint {
            case .color(let c): return c.a > 0 ? c : nil
            case .gradient(let g): return g.stops.first?.color
            }
        }
        return nil
    }
}

extension Page {

    /// Folds the selected layers, or the contents of a selected group, into
    /// one combined shape: dark fills union, light fills subtract, in painting
    /// order. Text is outlined first so its letters take part as geometry.
    @discardableResult
    public mutating func punchOut(_ ids: [String]) -> PunchOut.Outcome {
        let ordered = find(LayerQuery()).filter { ids.contains($0) }
        guard !ordered.isEmpty else { return .refused("Select the shapes to punch out") }

        let parents = Set(ordered.map { ancestors(of: $0).last })
        guard parents.count == 1, let parent = parents.first else {
            return .refused("Punch Out works on shapes inside one artboard or group")
        }

        // Letters are geometry once outlined, and the outline keeps the text's
        // fill, so a white word on a dark disc cuts through it like any other
        // light shape.
        for id in ordered { outlineText(in: id) }

        // Every piece, in painting order, as a path in the parent's space.
        var pieces: [(layer: Layer, path: CGPath)] = []
        var pictures = 0
        func gather(_ l: Layer, base: CGAffineTransform) {
            guard l.isVisible else { return }
            switch l.kind {
            case .group(let kids):
                for k in kids { gather(k, base: Compose.transform(l).concatenating(base)) }
            case .bitmap:
                pictures += 1
            default:
                guard let raw = Compose.resolvedPath(l) else { return }
                pieces.append((l, raw.transformed(by: Compose.transform(l).concatenating(base))))
            }
        }
        for id in ordered { if let l = layer(id) { gather(l, base: .identity) } }

        if pictures > 0 {
            return .refused("Punch Out works on shapes. Vectorize the picture first")
        }

        // A light shape under everything is paper, not a hole in anything, and
        // the fold starts at the first dark one.
        var members: [(layer: Layer, path: CGPath, ink: Bool)] = pieces.compactMap { piece in
            guard let color = PunchOut.paintColor(piece.layer) else { return nil }
            return (piece.layer, piece.path, PunchOut.isInk(color))
        }
        while let first = members.first, !first.ink { members.removeFirst() }
        guard !members.isEmpty else {
            return .refused("Nothing dark to keep — Punch Out needs at least one dark shape")
        }

        var box = CGRect.null
        for m in members { box = box.union(m.path.boundingBoxOfPath) }
        guard !box.isNull, box.width > 0, box.height > 0 else {
            return .refused("Those shapes have no area")
        }

        var built: [Layer] = []
        var inks = 0, holes = 0
        for (i, m) in members.enumerated() {
            let local = m.path.transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
            let frame = local.boundingBoxOfPath
            var l = Layer(kind: .path(local.transformed(by: CGAffineTransform(translationX: -frame.minX, y: -frame.minY)),
                                      closed: true))
            l.name = m.layer.name
            l.frame = frame
            l.style.fills = m.layer.style.fills
            l.style.borders = []
            l.booleanOp = i == 0 ? .none : (m.ink ? .union : .subtract)
            if m.ink { inks += 1 } else { holes += 1 }
            built.append(l)
        }

        for id in ordered { removeLayer(id) }

        var made = Layer(kind: .shapeGroup(built, .nonZero))
        made.name = "Punch Out"
        made.frame = box
        made.style.fills = [Fill(paint: .color(.black))]
        insertLayer(made, parent: parent, index: children(of: parent).count)
        return .made(id: made.id, inks: inks, holes: holes)
    }

    /// Outlines every text layer at or under `id`, in place.
    private mutating func outlineText(in id: String) {
        guard let l = layer(id) else { return }
        switch l.kind {
        case .text:
            convertToOutlines(id)
        case .group(let kids), .shapeGroup(let kids, _):
            for k in kids { outlineText(in: k.id) }
        default:
            break
        }
    }
}
