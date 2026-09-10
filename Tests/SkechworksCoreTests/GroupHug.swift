import CoreGraphics
import Foundation
import Testing
@testable import SkechworksCore

// A group's frame is the box around its children. See GroupHug.swift.

private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil),
                              closed: true))
    l.frame = CGRect(x: x, y: y, width: w, height: h)
    return l
}

@Test func aGroupThatLostItsBackdropShrinksToTheDrawingWithoutMovingIt() {
    // The SVG viewBox was 500 square; the drawing inside starts 13 in and
    // ends 27 short. The backdrop that filled the box is gone.
    var g = Layer(kind: .group([rect(13, 14, 460, 448), rect(200, 30, 20, 20)]))
    g.frame = CGRect(x: 100, y: 100, width: 500, height: 500)
    var page = Page(name: "p")
    page.layers = [g]

    let hugged = page.huggingGroups()
    let h = hugged.layers[0]
    #expect(h.frame == CGRect(x: 113, y: 114, width: 460, height: 448))
    // The children sit where they were on the page.
    #expect(Compose.visibleBounds(of: h) == Compose.visibleBounds(of: g))
    if case .group(let kids) = h.kind {
        #expect(kids[0].frame.origin == .zero)
        #expect(kids[1].frame.origin == CGPoint(x: 187, y: 16))
    } else {
        Issue.record("not a group")
    }
}

@Test func aTurnedGroupKeepsItsFrame() {
    var g = Layer(kind: .group([rect(13, 14, 460, 448)]))
    g.frame = CGRect(x: 100, y: 100, width: 500, height: 500)
    g.rotation = 30
    var page = Page(name: "p")
    page.layers = [g]
    #expect(page.huggingGroups().layers[0].frame == g.frame)
}

@Test func anArtboardKeepsItsSizeButTheGroupsInsideHug() {
    var inner = Layer(kind: .group([rect(10, 10, 100, 100)]))
    inner.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    var board = Layer(kind: .group([inner]))
    board.isArtboard = true
    board.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
    var page = Page(name: "p")
    page.layers = [board]
    let out = page.huggingGroups()
    #expect(out.layers[0].frame.size == CGSize(width: 500, height: 500))
    if case .group(let kids) = out.layers[0].kind {
        #expect(kids[0].frame == CGRect(x: 10, y: 10, width: 100, height: 100))
    }
}

@Test func aTurnedChildIsMeasuredTheWayItPaints() {
    var kid = rect(0, 0, 100, 20)
    kid.rotation = 90
    var g = Layer(kind: .group([kid]))
    g.frame = CGRect(x: 0, y: 0, width: 100, height: 20)
    var page = Page(name: "p")
    page.layers = [g]
    let out = page.huggingGroups().layers[0]
    // A 100x20 bar stood on end is 20 wide and 100 tall, centred where it was.
    #expect(abs(out.frame.width - 20) < 0.01)
    #expect(abs(out.frame.height - 100) < 0.01)
    #expect(abs(out.frame.midX - 50) < 0.01 && abs(out.frame.midY - 10) < 0.01)
}

@Test func aHuggedGroupIsLeftAlone() {
    var g = Layer(kind: .group([rect(0, 0, 200, 100)]))
    g.frame = CGRect(x: 5, y: 5, width: 200, height: 100)
    var page = Page(name: "p")
    page.layers = [g]
    #expect(page.huggingGroups().contentSignature == page.contentSignature)
}
