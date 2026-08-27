import Testing
import CoreGraphics
@testable import SketchyworksCore

@Test func groupingAcrossContainersGathersEverything() {
    // The eagle case: a background oval living on the artboard, the trace at
    // the page root. Group both: ONE group holding both, positions kept.
    var oval = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 200), transform: nil), closed: true))
    oval.frame = CGRect(x: 20, y: 30, width: 200, height: 200)
    var board = Layer(kind: .group([oval]))
    board.isArtboard = true
    board.frame = CGRect(x: 100, y: 100, width: 500, height: 500)
    var loose = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 50, height: 50), transform: nil), closed: true))
    loose.frame = CGRect(x: 200, y: 200, width: 50, height: 50)
    var page = Page(name: "p")
    page.layers = [board, loose]

    let ovalPageOrigin = CGPoint(x: 120, y: 130)   // board + oval offsets

    let made = page.group([oval.id, loose.id])
    let g = try! #require(made.flatMap { page.layer($0) })
    #expect(page.children(of: g.id).count == 2, "both members are in the group")
    #expect(page.layers.contains { $0.id == g.id }, "the group lives at the page root, the common container")
    #expect(page.children(of: board.id).isEmpty, "the oval left the artboard")

    // The oval kept its place on the canvas: group origin + child origin.
    let inGroup = try! #require(page.layer(oval.id))
    #expect(g.frame.minX + inGroup.frame.minX == ovalPageOrigin.x)
    #expect(g.frame.minY + inGroup.frame.minY == ovalPageOrigin.y)
}

@Test func groupingSiblingsStillWorksTheOldWay() {
    var a = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    a.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    var b = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    b.frame = CGRect(x: 30, y: 0, width: 10, height: 10)
    var page = Page(name: "p")
    page.layers = [a, b]
    let made = page.group([a.id, b.id])
    #expect(made != nil)
    #expect(page.layers.count == 1)
}
