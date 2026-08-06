import CoreGraphics
import Testing

@testable import AccompliceCore

// Where a drawn copy of an artboard goes.
//
// Beside the original, tops level, a clean gap between — and never on top of
// something that's already there.

private func board(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 100, _ h: CGFloat = 100) -> Layer {
    var l = Layer(kind: .group([]))
    l.isArtboard = true
    l.frame = CGRect(x: x, y: y, width: w, height: h)
    return l
}

private func page(_ boards: Layer...) -> Page {
    var p = Page(name: "t")
    p.layers = boards
    return p
}

@Test func theCopyLandsToTheRightWithAGapAndLevelTops() {
    let p = page(board(0, 0))
    let slot = p.freeSlot(size: CGSize(width: 100, height: 100), rightOf: p.layers[0].frame)
    #expect(slot.minX == 110, "expected a 10 gap, got x \(slot.minX)")
    #expect(slot.minY == 0, "tops must line up")
}

@Test func anOccupiedSlotIsSkippedForTheNextOneAlong() {
    // Something already parked immediately to the right.
    let p = page(board(0, 0), board(110, 0))
    let slot = p.freeSlot(size: CGSize(width: 100, height: 100), rightOf: p.layers[0].frame)
    #expect(slot.minX == 220)
    #expect(slot.minY == 0)
}

@Test func aFullRowDropsToTheNextOneDown() {
    var boards = [board(0, 0)]
    for i in 1...8 { boards.append(board(CGFloat(i) * 110, 0)) }
    var p = Page(name: "t")
    p.layers = boards
    let slot = p.freeSlot(size: CGSize(width: 100, height: 100), rightOf: boards[0].frame,
                          gap: 10, columns: 8)
    #expect(slot.minY == 110, "should have gone down a row, got y \(slot.minY)")
    #expect(slot.minX == 0, "a new row starts back at the anchor's left edge")
}

@Test func aChosenSlotNeverOverlapsAnything() {
    // The property that matters, over a scattering of awkward positions.
    var p = Page(name: "t")
    p.layers = [ board(0, 0), board(110, 0), board(220, 0), board(0, 110), board(115, 118, 80, 60) ]
    let slot = p.freeSlot(size: CGSize(width: 100, height: 100), rightOf: p.layers[0].frame)
    for existing in p.layers {
        #expect(!existing.frame.insetBy(dx: 1, dy: 1).intersects(slot),
                "landed on \(existing.frame)")
    }
}

@Test func touchingAtTheGapIsNotACollision() {
    // Boards placed a clean gap apart share no pixels; treating that as a clash
    // would push every copy one slot further out for no reason.
    let p = page(board(0, 0), board(220, 0))
    let slot = p.freeSlot(size: CGSize(width: 100, height: 100), rightOf: p.layers[0].frame)
    #expect(slot.minX == 110, "the empty gap between two boards should be used")
}

@Test func differentSizedBoardsAreRespected() {
    let p = page(board(0, 0, 300, 200))
    let slot = p.freeSlot(size: CGSize(width: 300, height: 200), rightOf: p.layers[0].frame)
    #expect(slot == CGRect(x: 310, y: 0, width: 300, height: 200))
}

@Test func anEmptyPageStillPlacesIt() {
    let p = Page(name: "t")
    let slot = p.freeSlot(size: CGSize(width: 100, height: 100),
                          rightOf: CGRect(x: 0, y: 0, width: 100, height: 100))
    #expect(slot.minX == 110)
}

@Test func theArtboardHoldingALayerIsFound() {
    var art = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    art.name = "art"
    var b = board(0, 0)
    b.kind = .group([ art ])
    var p = Page(name: "t")
    p.layers = [ b ]
    #expect(p.artboard(containing: art.id)?.id == b.id)
}

@Test func aLoosLayerHasNoArtboard() {
    var loose = Layer(kind: .path(CGPath(rect: .zero, transform: nil), closed: true))
    loose.name = "loose"
    var p = Page(name: "t")
    p.layers = [ loose ]
    #expect(p.artboard(containing: loose.id) == nil)
}

@Test func aNewBoardGoesPastTheOnesAlreadyThere() {
    // Insert ▸ Artboard used to land in the middle of the content bounds, which
    // on a page with work on it looked exactly like the work had been replaced.
    var p = page(board(0, 0, 400, 400), board(410, 0, 400, 400))
    let slot = p.nextBoardSlot(size: CGSize(width: 400, height: 400))
    #expect(slot.minX >= 820, "a new board landed on an existing one")
    for existing in p.layers {
        #expect(!existing.frame.insetBy(dx: 1, dy: 1).intersects(slot))
    }
    p.layers = []
    #expect(p.nextBoardSlot(size: CGSize(width: 400, height: 400)).origin == .zero,
            "the first board on an empty page belongs at the origin")
}

@Test func addingAnArtboardThroughTheApiPlacesItClear() {
    var p = page(board(0, 0, 300, 300))
    var spec = AddSpec()
    spec.kind = "artboard"
    spec.name = "Second"
    _ = p.add(spec)
    let made = p.layers.first { $0.name == "Second" }
    #expect(made != nil)
    #expect(made?.isArtboard == true)
    #expect(!p.layers[1].frame.insetBy(dx: 1, dy: 1).intersects(made!.frame),
            "the new board overlaps the old one")
}

@Test func anArtboardAskedForAtAPlaceStillGoesThere() {
    // Free-space placement is for boards with nowhere in particular to be. A
    // caller naming coordinates means them.
    var p = page(board(0, 0))
    var spec = AddSpec()
    spec.kind = "artboard"
    spec.name = "Exact"
    spec.x = 900
    spec.y = 500
    _ = p.add(spec)
    let made = p.layers.first { $0.name == "Exact" }
    #expect(made?.frame.origin == CGPoint(x: 900, y: 500))
}
