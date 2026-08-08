import CoreGraphics
import Testing

@testable import AccompliceCore

// Shearing a shape without moving it.
//
// Skew rides in the same matrix as rotation and flip, so every consumer —
// renderer, hit-testing, SVG export, boolean ops — gets it without being told.
// The thing that has to be right is the order: prepended, so the shape leans in
// its own axes. Appended, it would shear the shape's POSITION too, and a shape
// far from the origin would fly off the page.

private func box(_ frame: CGRect = CGRect(x: 200, y: 300, width: 100, height: 60)) -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil),
                              closed: true))
    l.frame = frame
    return l
}

private func corners(_ l: Layer) -> [CGPoint] {
    let t = Compose.transform(l)
    return [CGPoint(x: 0, y: 0), CGPoint(x: l.frame.width, y: 0),
            CGPoint(x: l.frame.width, y: l.frame.height), CGPoint(x: 0, y: l.frame.height)]
        .map { $0.applying(t) }
}

private func centre(_ l: Layer) -> CGPoint {
    let c = corners(l)
    return CGPoint(x: c.map(\.x).reduce(0, +) / 4, y: c.map(\.y).reduce(0, +) / 4)
}

@Test func noSkewChangesNothing() {
    let plain = box()
    var skewed = box()
    skewed.skewX = 0
    skewed.skewY = 0
    #expect(Compose.transform(plain) == Compose.transform(skewed))
}

@Test func skewLeavesTheShapeWhereItWas() {
    // The whole point of prepending. Appended, a shape 300 points down the page
    // would be flung sideways by the shear before it ever leaned.
    let before = centre(box())
    var l = box()
    l.skewX = 20
    let after = centre(l)
    #expect(abs(before.x - after.x) < 0.01)
    #expect(abs(before.y - after.y) < 0.01)
}

@Test func skewXLeansTheTopAndBottomOppositeWays() {
    var l = box()
    l.skewX = 30
    let c = corners(l)
    // Top edge goes one way, bottom edge the other, by tan(30) x half the height.
    let expected = tan(30 * CGFloat.pi / 180) * l.frame.height / 2
    #expect(abs((c[0].x - 200) + expected) < 0.01)      // top-left, pushed left
    #expect(abs((c[3].x - 200) - expected) < 0.01)      // bottom-left, pushed right
    // Heights don't move: this is a horizontal shear.
    #expect(abs(c[0].y - 300) < 0.01)
    #expect(abs(c[3].y - 360) < 0.01)
}

@Test func skewYLeansTheSidesInstead() {
    var l = box()
    l.skewY = 30
    let c = corners(l)
    let expected = tan(30 * CGFloat.pi / 180) * l.frame.width / 2
    #expect(abs((c[0].y - 300) + expected) < 0.01)      // left edge lifted
    #expect(abs((c[1].y - 300) - expected) < 0.01)      // right edge dropped
    #expect(abs(c[0].x - 200) < 0.01)
}

@Test func aShearedShapeIsStillAParallelogram() {
    var l = box()
    l.skewX = 25
    l.skewY = -12
    l.rotation = 18
    let c = corners(l)
    // Opposite sides stay parallel and equal — that is what makes this affine,
    // and what separates it from a bitmap's four-corner perspective quad.
    let top = CGPoint(x: c[1].x - c[0].x, y: c[1].y - c[0].y)
    let bottom = CGPoint(x: c[2].x - c[3].x, y: c[2].y - c[3].y)
    #expect(abs(top.x - bottom.x) < 0.01 && abs(top.y - bottom.y) < 0.01)
}

@Test func skewSurvivesASaveAndReopen() throws {
    var l = box()
    l.skewX = 22.5
    l.skewY = -8.25
    l.name = "Leaning"
    var page = Page(name: "P")
    page.layers = [l]
    var doc = Document()
    doc.pages = [page]

    let data = try AcmplcFile.write(document: doc, images: [:])
    let (reopened, _) = try AcmplcFile.read(data)
    let back = try #require(reopened.pages.first?.layers.first)

    #expect(abs(back.skewX - 22.5) < 0.001)
    #expect(abs(back.skewY - (-8.25)) < 0.001)
}

@Test func anUnskewedLayerWritesNothingExtra() throws {
    var page = Page(name: "P")
    page.layers = [box()]
    var doc = Document()
    doc.pages = [page]
    let text = String(decoding: try AcmplcFile.write(document: doc, images: [:]), as: UTF8.self)
    // A shape nobody skewed shouldn't grow two zeroes in the file.
    #expect(!text.contains("skewX"))
    #expect(!text.contains("skewY"))
}

// Solving a drag back into angles.
//
// The round trip is the test that matters: put a corner somewhere, ask for the
// shear that lands it there, apply it, and the corner should be where it was
// put. A sign error passes every test that only checks "something changed".

private func cornerOnPage(_ l: Layer, _ i: Int) -> CGPoint {
    let f = l.frame
    return [CGPoint(x: 0, y: 0), CGPoint(x: f.width, y: 0),
            CGPoint(x: f.width, y: f.height), CGPoint(x: 0, y: f.height)][i]
        .applying(Compose.transform(l))
}

@Test func draggingACornerLandsItWhereItWasDragged() {
    for corner in 0..<4 {
        for move in [CGPoint(x: 18, y: 0), CGPoint(x: -14, y: 0),
                     CGPoint(x: 0, y: 11), CGPoint(x: 9, y: -7)] {
            var l = box()
            let unsheared = Compose.transform(l)
            let from = cornerOnPage(l, corner)
            let want = CGPoint(x: from.x + move.x, y: from.y + move.y)

            let angles = Compose.skew(placing: corner,
                                      at: want.applying(unsheared.inverted()), of: l)
            l.skewX = angles.x
            l.skewY = angles.y

            let landed = cornerOnPage(l, corner)
            #expect(abs(landed.x - want.x) < 0.01, "corner \(corner) move \(move)")
            #expect(abs(landed.y - want.y) < 0.01, "corner \(corner) move \(move)")
        }
    }
}

@Test func draggingTheTopRightCornerRightLeansTheTopRight() {
    var l = box()
    let unsheared = Compose.transform(l)
    let from = cornerOnPage(l, 1)
    let want = CGPoint(x: from.x + 20, y: from.y)
    let angles = Compose.skew(placing: 1, at: want.applying(unsheared.inverted()), of: l)
    l.skewX = angles.x
    l.skewY = angles.y

    // A shear slides the whole top edge across as one, it doesn't splay it, so
    // both top corners move right by the same 20 and the bottom two go left by
    // it. If the sign were flipped the shape would lean away from the pointer
    // and every "did something change" test would still pass.
    #expect(abs(cornerOnPage(l, 0).x - 220) < 0.01)
    #expect(abs(cornerOnPage(l, 1).x - 320) < 0.01)
    #expect(abs(cornerOnPage(l, 3).x - 180) < 0.01)
    #expect(abs(cornerOnPage(l, 2).x - 280) < 0.01)
}

@Test func theOppositeCornerStaysPutUnderASkew() {
    var l = box()
    let unsheared = Compose.transform(l)
    let want = CGPoint(x: cornerOnPage(l, 1).x + 20, y: cornerOnPage(l, 1).y)
    let angles = Compose.skew(placing: 1, at: want.applying(unsheared.inverted()), of: l)
    l.skewX = angles.x
    l.skewY = angles.y
    // A shear about the centre moves opposite corners by equal and opposite
    // amounts, so the centre itself never budges.
    #expect(abs(centre(l).x - 250) < 0.01)
    #expect(abs(centre(l).y - 330) < 0.01)
}

@Test func aDegenerateFrameIsLeftAlone() {
    var l = box(CGRect(x: 0, y: 0, width: 0, height: 0))
    l.skewX = 7
    let angles = Compose.skew(placing: 0, at: CGPoint(x: 50, y: 50), of: l)
    #expect(angles.x == 7)   // unchanged, rather than NaN
}

@Test func everythingDownstreamSeesTheSkew() {
    // The claim worth checking: skew rides in the same matrix as rotation, so
    // nothing had to be taught about it. If a consumer built its own transform
    // instead of asking Compose, this catches it.
    var l = box()
    l.name = "Leaner"
    l.style.fills = [Fill(paint: .color(Color(r: 1, g: 0, b: 0, a: 1)))]
    var page = Page(name: "P")
    page.layers = [l]

    let upright = SVGWriter(images: [:]).svg(page: page)
    page.layers[0].skewX = 30
    let leaning = SVGWriter(images: [:]).svg(page: page)
    #expect(upright != leaning, "SVG export ignored the skew")

    // And hit-testing: the top-left corner has moved left, so a point just
    // outside the old corner is now inside the shape.
    let sheared = Compose.resolvedPath(page.layers[0])!
        .transformed(by: Compose.transform(page.layers[0]))
    #expect(sheared.boundingBoxOfPath.minX < 200)
}
