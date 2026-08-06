import CoreGraphics
import Foundation

extension Page {

    /// Somewhere to put a new board of `size` next to `anchor`, without landing
    /// on anything already there.
    ///
    /// Reads the way a person would place it: immediately to the right, top
    /// edges level. If that's taken, keep going right; when that stops being
    /// "next to it" in any useful sense, drop to the next row and start from
    /// the anchor's left edge again. Failing everything, it goes below the lot
    /// rather than on top of something.
    ///
    /// Occupancy is judged against top-level layers only. Something nested is
    /// inside a board that's already counted, and counting both would rule out
    /// the row a board's own contents sit in.
    public func freeSlot(size: CGSize, rightOf anchor: CGRect,
                         gap: CGFloat = 10, columns: Int = 8) -> CGRect {
        let taken = layers.filter(\.isVisible).map(\.bounds)

        // A shared edge is not a collision: boards placed a clean gap apart
        // touch at the gap and are meant to.
        func free(_ candidate: CGRect) -> Bool {
            let probe = candidate.insetBy(dx: 0.5, dy: 0.5)
            return !taken.contains { $0.intersects(probe) }
        }

        let step = CGSize(width: size.width + gap, height: size.height + gap)
        var row = 0
        // Rows are bounded so a page with a long diagonal of boards can't spin
        // here; past that it goes underneath everything, which is always free.
        while row < 64 {
            let y = anchor.minY + CGFloat(row) * step.height
            // Row 0 starts beside the anchor. Later rows start at its left edge,
            // because "below and back to the margin" is where the eye expects
            // the next one, not below and far to the right.
            let firstX = row == 0 ? anchor.maxX + gap : anchor.minX
            for column in 0..<columns {
                let candidate = CGRect(origin: CGPoint(x: firstX + CGFloat(column) * step.width, y: y),
                                       size: size)
                if free(candidate) { return candidate }
            }
            row += 1
        }

        let below = contentBounds()
        return CGRect(origin: CGPoint(x: anchor.minX, y: below.maxY + gap), size: size)
    }

    /// Where a brand-new board of `size` should land: past the rightmost board
    /// already on the page, or at the origin when the page is empty.
    ///
    /// Every way a board arrives goes through here — drawn, vectorized, pasted,
    /// or inserted blank — so none of them lands on top of another. A new board
    /// used to appear in the middle of whatever was already there, which looked
    /// exactly like the work had been replaced.
    public func nextBoardSlot(size: CGSize, gap: CGFloat = 10) -> CGRect {
        let boards = layers.filter { $0.isArtboard && $0.isVisible }.map(\.frame)
        guard let rightmost = boards.max(by: { $0.maxX < $1.maxX }) else {
            return CGRect(origin: .zero, size: size)
        }
        return freeSlot(size: size, rightOf: rightmost, gap: gap)
    }

    /// The artboard a layer sits on, if it sits on one.
    public func artboard(containing id: String) -> Layer? {
        ancestors(of: id).reversed().compactMap { layer($0) }.first(where: \.isArtboard)
    }
}
