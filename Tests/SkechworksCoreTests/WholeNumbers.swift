import CoreGraphics
import Testing

@testable import SkechworksCore

// Round to Pixel, on request, puts a frame on whole numbers. 791.8 by 792.1
// after a resize by hand was how a disc ended up a hair past its board.

private func square(_ frame: CGRect) -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil), closed: true))
    l.frame = frame
    return l
}

@Test func aFractionalFrameRoundsAndItsPathFollows() {
    var l = square(CGRect(x: 10.4, y: 20.6, width: 791.8, height: 792.1))
    l.snapFrameToWholeNumbers()

    #expect(l.frame == CGRect(x: 10, y: 21, width: 792, height: 792))
    guard case .path(let p, _) = l.kind else { Issue.record("not a path"); return }
    #expect(abs(p.boundingBoxOfPath.width - 792) < 0.001)
    #expect(abs(p.boundingBoxOfPath.height - 792) < 0.001)
}

@Test func aWholeFrameIsLeftAlone() {
    var l = square(CGRect(x: 10, y: 20, width: 100, height: 50))
    let before = l
    l.snapFrameToWholeNumbers()
    #expect(l.frame == before.frame)
    #expect(l.frameIsWhole)
}

@Test func aFrameNeverRoundsBelowOne() {
    var l = square(CGRect(x: 0, y: 0, width: 0.3, height: 0.4))
    l.snapFrameToWholeNumbers()
    #expect(l.frame.size == CGSize(width: 1, height: 1))
}

@Test func anArtboardRoundsWithoutScalingItsChildren() {
    let kid = square(CGRect(x: 10, y: 10, width: 50, height: 50))
    var board = Layer(kind: .group([ kid ]))
    board.isArtboard = true
    board.frame = CGRect(x: 0, y: 0, width: 500.4, height: 499.6)
    var page = Page(name: "t")
    page.layers = [ board ]

    page.updateLayer(board.id) { $0.snapFrameToWholeNumbers() }

    #expect(page.layer(board.id)?.frame == CGRect(x: 0, y: 0, width: 500, height: 500))
    #expect(page.layer(kid.id)?.frame == kid.frame)
}
