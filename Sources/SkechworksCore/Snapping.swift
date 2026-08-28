import CoreGraphics
import Foundation

/// Alignment snapping, and the guides that explain it.
///
/// The thing that makes a design tool feel like one. Without it, centring a word on a
/// disc means nudging by one and squinting; with it the object arrives where you meant
/// and a line appears saying why.
///
/// Deliberately here rather than in the canvas, because the interesting parts — which
/// candidate wins when two are equally close, what happens when both an edge and a
/// centre are in range, whether the guide spans the right extent — are all decidable
/// from rectangles alone, and none of them are testable through a mouse.
public enum Snapping {

    /// Which line of a rectangle is being aligned.
    public enum Edge: Sendable, Equatable {
        case leading, center, trailing      // on whichever axis is in play
    }

    public struct Guide: Sendable, Equatable {
        /// True for a vertical line (aligning x), false for a horizontal one.
        public let vertical: Bool
        /// Where the line sits, in page coordinates.
        public let position: CGFloat
        /// How far the line runs, so it visibly connects the two things it relates.
        public let from: CGFloat
        public let to: CGFloat

        public init(vertical: Bool, position: CGFloat, from: CGFloat, to: CGFloat) {
            self.vertical = vertical
            self.position = position
            self.from = min(from, to)
            self.to = max(from, to)
        }
    }

    public struct Result: Sendable, Equatable {
        /// What to add to the proposed position to land on the snap.
        public var adjustment: CGSize
        public var guides: [Guide]

        public static let none = Result(adjustment: .zero, guides: [])
        public var snapped: Bool { adjustment != .zero || !guides.isEmpty }
    }

    /// Snaps `moving` against `others`, returning the correction to apply.
    ///
    /// `tolerance` is in page units. The caller divides a fixed number of screen
    /// pixels by the zoom, so snapping feels the same at 25% as at 400% — a tolerance
    /// fixed in page units would be unusably grabby zoomed out and unreachable
    /// zoomed in.
    public static func snap(_ moving: CGRect,
                            to others: [CGRect],
                            tolerance: CGFloat) -> Result {
        guard tolerance > 0, !others.isEmpty, !moving.isNull else { return .none }

        let x = best(moving: lines(moving, vertical: true),
                     others: others.map { (lines($0, vertical: true), $0) },
                     tolerance: tolerance)
        let y = best(moving: lines(moving, vertical: false),
                     others: others.map { (lines($0, vertical: false), $0) },
                     tolerance: tolerance)

        var guides: [Guide] = []
        if let x { guides.append(guide(x, moving: moving, vertical: true)) }
        if let y { guides.append(guide(y, moving: moving, vertical: false)) }

        return Result(adjustment: CGSize(width: x?.delta ?? 0, height: y?.delta ?? 0),
                      guides: guides)
    }

    /// The three lines a rectangle offers on one axis.
    private static func lines(_ r: CGRect, vertical: Bool) -> [(Edge, CGFloat)] {
        vertical
            ? [(.leading, r.minX), (.center, r.midX), (.trailing, r.maxX)]
            : [(.leading, r.minY), (.center, r.midY), (.trailing, r.maxY)]
    }

    private struct Match {
        var delta: CGFloat          // what to add to the moving rect
        var position: CGFloat       // where the guide goes, in page space
        var other: CGRect
    }

    /// The closest alignment within tolerance, or nothing.
    ///
    /// Ties go to the candidate found first, and the candidates are ordered
    /// leading/centre/trailing over `others` in the order given — so with a rect
    /// exactly between two others, the answer is stable rather than depending on
    /// which way the mouse last moved. A wobbling snap is worse than none.
    private static func best(moving: [(Edge, CGFloat)],
                             others: [([(Edge, CGFloat)], CGRect)],
                             tolerance: CGFloat) -> Match? {
        var found: Match?
        var bestDistance = tolerance
        for (_, mine) in moving {
            for (theirs, rect) in others {
                for (_, line) in theirs {
                    let delta = line - mine
                    let distance = abs(delta)
                    // Strictly closer, so the first of equally-close candidates wins.
                    if distance < bestDistance {
                        bestDistance = distance
                        found = Match(delta: delta, position: line, other: rect)
                    }
                }
            }
        }
        return found
    }

    /// A guide long enough to reach both rectangles, so it reads as a relationship
    /// rather than a stray line. Drawn from the moved position, not the proposed one.
    private static func guide(_ m: Match, moving: CGRect, vertical: Bool) -> Guide {
        let moved = moving.offsetBy(dx: vertical ? m.delta : 0, dy: vertical ? 0 : m.delta)
        if vertical {
            return Guide(vertical: true, position: m.position,
                         from: min(moved.minY, m.other.minY),
                         to: max(moved.maxY, m.other.maxY))
        }
        return Guide(vertical: false, position: m.position,
                     from: min(moved.minX, m.other.minX),
                     to: max(moved.maxX, m.other.maxX))
    }
}

extension Page {

    /// The rectangles worth snapping to when `moving` is being dragged.
    ///
    /// Everything visible except the layers being moved and anything inside them — a
    /// layer that snapped to its own children would be unmovable, and one that snapped
    /// to itself would never move at all.
    public func snapTargets(excluding moving: Set<String>) -> [CGRect] {
        var excluded = moving
        for id in moving {
            if let l = layer(id) { collectIDs(l, into: &excluded) }
        }
        var rects: [CGRect] = []
        for l in layers { gather(l, at: .zero, excluding: excluded, into: &rects) }
        return rects
    }

    private func collectIDs(_ l: Layer, into set: inout Set<String>) {
        set.insert(l.id)
        if case .group(let children) = l.kind {
            for c in children { collectIDs(c, into: &set) }
        }
    }

    /// Artboards contribute their own frame and their children's, so you can align to
    /// the edge of the board and to what's already on it.
    private func gather(_ l: Layer, at origin: CGPoint, excluding: Set<String>,
                        into rects: inout [CGRect]) {
        guard l.isVisible else { return }
        let frame = CGRect(x: origin.x + l.frame.minX, y: origin.y + l.frame.minY,
                           width: l.frame.width, height: l.frame.height)
        if !excluding.contains(l.id) { rects.append(frame) }
        if case .group(let children) = l.kind {
            for c in children {
                gather(c, at: frame.origin, excluding: excluding, into: &rects)
            }
        }
    }
}
