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
/// The result is ONE plain path, not a live combined shape. The first cut of
/// this kept the pieces live inside a shape group, the way Subtract does, and
/// the skull coin (651 pieces, 17,000 path elements) took twenty seconds to
/// fold in a release build — which the canvas then asked for again on every
/// mouse move, and the app never came back. A fold that size runs once, off
/// the main thread, and what it puts down has to be cheap to draw. Undo is
/// the way back to the pieces.
///
/// Three steps so the app can put the slow one on another thread: `prepare`
/// reads the page, `Prepared.fold` does the geometry, `Page.apply` writes the
/// result. `Page.punchOut` runs all three for callers that can block.
public enum PunchOut {
    public struct Refusal: Error { public let why: String }

    public enum Outcome: Equatable {
        /// The path's id, how many dark pieces went in and how many light ones
        /// cut holes.
        case made(id: String, inks: Int, holes: Int)
        case refused(String)
    }

    /// Everything the fold needs, read off the page and owned by the caller,
    /// so the page can go on being edited while the geometry runs.
    public struct Prepared: @unchecked Sendable {
        /// Pieces in painting order, each in the parent's space. Ink adds,
        /// paper cuts.
        public let pieces: [(path: CGPath, ink: Bool)]
        public let parent: String?
        /// What gets removed when the result goes down.
        public let originals: [String]
        public var inks: Int { pieces.filter(\.ink).count }
        public var holes: Int { pieces.count - inks }

        /// The fold. Runs of the same operation are stacked and applied in one
        /// planar pass, since A − B − C is A − (B ∪ C), so a coin is a few
        /// passes rather than one per glyph. Checks for cancellation between
        /// passes; a single pass can't be interrupted.
        public func fold() throws -> CGPath? {
            var acc: CGPath?
            var pending: [CGPath] = []
            var cuts: [CGPath] = []
            func stacked(_ paths: [CGPath]) -> CGPath {
                let stack = CGMutablePath()
                for p in paths { stack.addPath(p.normalized(using: .winding)) }
                return stack.normalized(using: .winding)
            }
            func flushCuts() throws {
                guard !cuts.isEmpty else { return }
                try Task.checkCancellation()
                let merged = stacked(cuts)
                cuts = []
                acc = acc?.subtracting(merged, using: .winding)
            }
            func flush() throws {
                try flushCuts()
                guard !pending.isEmpty else { return }
                try Task.checkCancellation()
                let merged = stacked(pending)
                pending = []
                acc = acc.map { $0.union(merged, using: .winding) } ?? merged
            }
            for piece in pieces {
                if piece.ink {
                    try flushCuts()
                    pending.append(piece.path)
                } else {
                    if !pending.isEmpty { try flush() }
                    cuts.append(piece.path)
                }
            }
            try flush()
            return acc
        }
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

    /// What a layer would contribute, in its own space. Text is outlined here
    /// rather than on the page, so preparing changes nothing.
    static func geometry(_ l: Layer) -> CGPath? {
        if case .text(let run) = l.kind {
            return TextOutline.path(run, in: CGRect(origin: .zero, size: l.frame.size))
        }
        return Compose.resolvedPath(l)
    }

    /// The colour a layer paints with; for text, the run's colour when the
    /// style has none, which is what the canvas falls back to.
    static func color(of l: Layer) -> Color? {
        if let c = paintColor(l) { return c }
        if case .text(let run) = l.kind { return run.color }
        return nil
    }

    /// Reads the selected layers, or the contents of a selected group, into
    /// pieces in painting order. Nothing on the page changes.
    public static func prepare(_ page: Page, _ ids: [String]) -> Result<Prepared, Refusal> {
        let ordered = page.find(LayerQuery()).filter { ids.contains($0) }
        guard !ordered.isEmpty else { return .failure(Refusal(why: "Select the shapes to punch out")) }

        let parents = Set(ordered.map { page.ancestors(of: $0).last })
        guard parents.count == 1, let parent = parents.first else {
            return .failure(Refusal(why: "Punch Out works on shapes inside one artboard or group"))
        }

        var pieces: [(path: CGPath, ink: Bool)] = []
        var pictures = 0
        func gather(_ l: Layer, base: CGAffineTransform) {
            guard l.isVisible else { return }
            switch l.kind {
            case .group(let kids):
                for k in kids { gather(k, base: Compose.transform(l).concatenating(base)) }
            case .bitmap:
                pictures += 1
            default:
                guard let raw = geometry(l), let c = color(of: l) else { return }
                pieces.append((raw.transformed(by: Compose.transform(l).concatenating(base)), isInk(c)))
            }
        }
        for id in ordered { if let l = page.layer(id) { gather(l, base: .identity) } }

        if pictures > 0 {
            return .failure(Refusal(why: "Punch Out works on shapes. Vectorize the picture first"))
        }
        // A light shape under everything is paper, not a hole in anything, and
        // the fold starts at the first dark one.
        while let first = pieces.first, !first.ink { pieces.removeFirst() }
        guard !pieces.isEmpty else {
            return .failure(Refusal(why: "Nothing dark to keep — Punch Out needs at least one dark shape"))
        }
        return .success(Prepared(pieces: pieces, parent: parent, originals: ordered))
    }
}

extension Page {

    /// Puts the folded path down in place of the pieces: one plain shape,
    /// filled black, where the topmost of them was.
    @discardableResult
    public mutating func apply(_ prepared: PunchOut.Prepared, folded: CGPath?) -> PunchOut.Outcome {
        guard let folded, !folded.isEmpty else { return .refused("Those shapes have no area") }
        // The pieces may have gone while the fold ran. Better to say so than to
        // put a shape down beside whatever replaced them.
        guard prepared.originals.allSatisfy({ layer($0) != nil }) else {
            return .refused("The shapes changed while Punch Out was running. Run it again")
        }
        let box = folded.boundingBoxOfPath
        guard box.width > 0, box.height > 0 else { return .refused("Those shapes have no area") }

        for id in prepared.originals { removeLayer(id) }

        var made = Layer(kind: .path(folded.transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY)),
                                     closed: true))
        made.name = "Punch Out"
        made.frame = box
        made.style.fills = [Fill(paint: .color(.black))]
        insertLayer(made, parent: prepared.parent, index: children(of: prepared.parent).count)
        return .made(id: made.id, inks: prepared.inks, holes: prepared.holes)
    }

    /// All three steps, blocking. For the document API and tests; the app
    /// folds on another thread.
    @discardableResult
    public mutating func punchOut(_ ids: [String]) -> PunchOut.Outcome {
        switch PunchOut.prepare(self, ids) {
        case .failure(let r): return .refused(r.why)
        case .success(let prepared):
            guard let folded = try? prepared.fold() else { return .refused("Punch Out was stopped") }
            return apply(prepared, folded: folded)
        }
    }
}
