import Testing
import CoreGraphics
@testable import AccompliceCore

@Test func aMarqueeSelectsArtOnTheBoardButNeverTheBoard() {
    // An artboard at (100,100) with a child square at its local (50,50),
    // plus a loose path at the page root overlapping the same region.
    var child = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 40, height: 40), transform: nil), closed: true))
    child.frame = CGRect(x: 50, y: 50, width: 40, height: 40)
    var board = Layer(kind: .group([child]))
    board.isArtboard = true
    board.frame = CGRect(x: 100, y: 100, width: 500, height: 500)
    var loose = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 30, height: 30), transform: nil), closed: true))
    loose.frame = CGRect(x: 160, y: 120, width: 30, height: 30)
    var page = Page(name: "p")
    page.layers = [board, loose]

    // Band inside the board, over both shapes (page coords).
    let hits = page.marqueeHits(CGRect(x: 120, y: 110, width: 120, height: 120))
    #expect(hits.contains(child.id), "art inside the artboard is selectable by band")
    #expect(hits.contains(loose.id))
    #expect(!hits.contains(board.id), "the artboard itself never marquee-selects")

    // Band over bare board only: nothing.
    #expect(page.marqueeHits(CGRect(x: 400, y: 400, width: 80, height: 80)).isEmpty)
}
