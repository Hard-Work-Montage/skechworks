import CoreGraphics
import Testing

@testable import SketchyworksCore

// Resizing a board gives you more room. It does not make the drawing bigger.
//
// An artboard is a frame around work, not a container that owns its size.
// Sketch changed this and it is a large part of why this app exists, so it gets
// tests rather than a comment.

private func shape(_ r: CGRect, _ name: String = "art") -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(origin: .zero, size: r.size), transform: nil), closed: true))
    l.frame = r
    l.name = name
    return l
}

private func board(_ frame: CGRect, holding kids: [Layer]) -> Page {
    var b = Layer(kind: .group(kids))
    b.isArtboard = true
    b.frame = frame
    b.name = "Artboard"
    var p = Page(name: "t")
    p.layers = [b]
    return p
}

private func kids(_ p: Page) -> [Layer] {
    guard case .group(let k) = p.layers[0].kind else { return [] }
    return k
}

@Test func growingABoardLeavesTheArtworkAlone() {
    var p = board(CGRect(x: 0, y: 0, width: 400, height: 400),
                  holding: [shape(CGRect(x: 50, y: 50, width: 100, height: 100))])
    p.layers[0].resize(to: CGSize(width: 800, height: 800))
    #expect(p.layers[0].frame.size == CGSize(width: 800, height: 800))
    let art = kids(p)[0]
    #expect(art.frame == CGRect(x: 50, y: 50, width: 100, height: 100),
            "the drawing was resized with the board: \(art.frame)")
}

@Test func shrinkingABoardLeavesTheArtworkAlone() {
    var p = board(CGRect(x: 0, y: 0, width: 400, height: 400),
                  holding: [shape(CGRect(x: 50, y: 50, width: 100, height: 100))])
    p.layers[0].resize(to: CGSize(width: 200, height: 200))
    #expect(kids(p)[0].frame == CGRect(x: 50, y: 50, width: 100, height: 100))
}

@Test func aPlainGroupStillResizesItsContents() {
    // The rule is about boards, not about everything. Dragging a group's handle
    // has always scaled what's in it and should keep doing so.
    var g = Layer(kind: .group([ shape(CGRect(x: 10, y: 10, width: 100, height: 100)) ]))
    g.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    g.resize(to: CGSize(width: 400, height: 400))
    guard case .group(let k) = g.kind else { Issue.record("not a group"); return }
    #expect(k[0].frame == CGRect(x: 20, y: 20, width: 200, height: 200),
            "a group stopped scaling its contents")
}

@Test func draggingTheLeftEdgeLeavesTheArtWhereItWas() {
    // The board's origin moves, and its contents are stored relative to it —
    // so without compensation the drawing slides across the canvas with the edge.
    var p = board(CGRect(x: 100, y: 0, width: 400, height: 400),
                  holding: [shape(CGRect(x: 50, y: 50, width: 100, height: 100))])
    let id = p.layers[0].id
    // Dragging the left edge out to x=0: anchored on the right, twice as wide.
    p.scale([id], about: CGPoint(x: 500, y: 0), by: CGSize(width: 2, height: 1),
            from: [id: CGRect(x: 100, y: 0, width: 400, height: 400)])

    let b = p.layers[0]
    #expect(b.frame.minX == -300, "the board should have grown leftward, got \(b.frame.minX)")
    // The art sat at page x = 100 + 50 = 150 and must still be there.
    let art = kids(p)[0]
    #expect(b.frame.minX + art.frame.minX == 150,
            "the drawing moved with the edge: now at \(b.frame.minX + art.frame.minX)")
    #expect(art.frame.size == CGSize(width: 100, height: 100), "and it must not have stretched")
}

@Test func draggingTheRightEdgeAlsoLeavesItAlone() {
    var p = board(CGRect(x: 0, y: 0, width: 400, height: 400),
                  holding: [shape(CGRect(x: 50, y: 50, width: 100, height: 100))])
    let id = p.layers[0].id
    p.scale([id], about: .zero, by: CGSize(width: 2, height: 1),
            from: [id: CGRect(x: 0, y: 0, width: 400, height: 400)])
    let art = kids(p)[0]
    #expect(art.frame == CGRect(x: 50, y: 50, width: 100, height: 100))
    #expect(p.layers[0].frame.width == 800)
}
