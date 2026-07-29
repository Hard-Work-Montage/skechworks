import Testing
import CoreGraphics
@testable import AccompliceCore

private func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

@Test func snapsToAnEdgeThatIsNearlyAligned() {
    // Left edges three units apart, tolerance four: it should close the gap.
    let result = Snapping.snap(r(103, 200, 50, 50), to: [r(100, 0, 50, 50)], tolerance: 4)
    #expect(result.adjustment.width == -3)
    #expect(result.adjustment.height == 0)
}

@Test func leavesThingsAloneWhenNothingIsClose() {
    let result = Snapping.snap(r(300, 300, 50, 50), to: [r(0, 0, 50, 50)], tolerance: 4)
    #expect(result == .none)
    #expect(!result.snapped)
}

@Test func centresAgainstCentres() {
    // The one that matters for a coin: a word centred on a disc.
    let disc = r(0, 0, 200, 200)                 // centre 100,100
    let word = r(38, 61, 120, 20)                // centre 98,71
    let result = Snapping.snap(word, to: [disc], tolerance: 5)
    #expect(result.adjustment.width == 2)        // 98 -> 100
    let moved = word.offsetBy(dx: result.adjustment.width, dy: result.adjustment.height)
    #expect(moved.midX == disc.midX)
}

@Test func snapsBothAxesIndependently() {
    let result = Snapping.snap(r(98, 202, 50, 50), to: [r(100, 200, 80, 80)], tolerance: 4)
    #expect(result.adjustment.width == 2)
    #expect(result.adjustment.height == -2)
    #expect(result.guides.count == 2)
    #expect(result.guides.contains { $0.vertical })
    #expect(result.guides.contains { !$0.vertical })
}

@Test func takesTheNearestOfCompetingCandidates() {
    // Left edge is 1 away, centre is 3 away. The nearer one wins.
    let moving = r(101, 500, 100, 10)
    let result = Snapping.snap(moving, to: [r(100, 0, 100, 10), r(54, 0, 100, 10)], tolerance: 6)
    #expect(result.adjustment.width == -1)
}

/// A snap that flips between two equally-good answers as the mouse jitters is worse
/// than no snap at all, so ties resolve the same way every time.
@Test func tiesResolveTheSameWayEveryTime() {
    let moving = r(100, 0, 20, 20)               // between two rects, 10 either side
    let others = [r(90, 0, 20, 20), r(110, 0, 20, 20)]
    let first = Snapping.snap(moving, to: others, tolerance: 15)
    #expect(first.snapped)
    for _ in 0..<50 {
        #expect(Snapping.snap(moving, to: others, tolerance: 15) == first)
    }
}

@Test func toleranceOfZeroMeansNoSnapping() {
    #expect(Snapping.snap(r(100, 0, 10, 10), to: [r(100, 50, 10, 10)], tolerance: 0) == .none)
}

@Test func theGuideReachesBothThingsItRelates() {
    // Vertical guide between a rect low on the page and one high up: it has to span
    // from the top of one to the bottom of the other, or it looks like a stray mark.
    let result = Snapping.snap(r(100, 500, 50, 50), to: [r(100, 0, 50, 50)], tolerance: 4)
    let guide = try! #require(result.guides.first { $0.vertical })
    #expect(guide.position == 100)
    #expect(guide.from == 0)
    #expect(guide.to == 550)
}

@Test func snapTargetsSkipTheLayersBeingMovedAndTheirContents() {
    var child = Layer(kind: .path(CGPath(rect: r(0, 0, 10, 10), transform: nil), closed: true))
    child.id = "child"; child.frame = r(10, 10, 10, 10)

    var group = Layer(kind: .group([child]))
    group.id = "group"; group.frame = r(0, 0, 100, 100)

    var other = Layer(kind: .path(CGPath(rect: r(0, 0, 10, 10), transform: nil), closed: true))
    other.id = "other"; other.frame = r(300, 300, 40, 40)

    var page = Page(name: "P")
    page.layers = [group, other]

    let targets = page.snapTargets(excluding: ["group"])
    // The group's own frame and its child's are both gone; a layer that snapped to
    // its own children could never be dragged anywhere.
    #expect(targets.count == 1)
    #expect(targets.first == r(300, 300, 40, 40))
}

@Test func childrenOfAnArtboardAreOfferedInPageCoordinates() {
    var inner = Layer(kind: .path(CGPath(rect: r(0, 0, 10, 10), transform: nil), closed: true))
    inner.id = "inner"; inner.frame = r(50, 60, 10, 10)

    var board = Layer(kind: .group([inner]))
    board.id = "board"; board.isArtboard = true; board.frame = r(1000, 2000, 500, 500)

    var page = Page(name: "P")
    page.layers = [board]

    let targets = page.snapTargets(excluding: [])
    #expect(targets.contains(r(1000, 2000, 500, 500)))
    // Absolute, not relative to the board — snapping compares against a dragged
    // rectangle that is itself in page space.
    #expect(targets.contains(r(1050, 2060, 10, 10)))
}

@Test func hiddenLayersAreNotSnappedTo() {
    var hidden = Layer(kind: .path(CGPath(rect: r(0, 0, 10, 10), transform: nil), closed: true))
    hidden.id = "hidden"; hidden.frame = r(100, 100, 10, 10); hidden.isVisible = false

    var page = Page(name: "P")
    page.layers = [hidden]
    #expect(page.snapTargets(excluding: []).isEmpty)
}
