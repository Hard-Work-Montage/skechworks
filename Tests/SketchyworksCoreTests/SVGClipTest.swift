import CoreGraphics
import Testing

@testable import SketchyworksCore

// Clips that clip nothing don't go in the file.
//
// Everything on an artboard is clipped to the board's edge, which is right on a
// canvas and pointless in a file when the shape sits well inside it. Sketch
// turns every clip-path into a "Clipped" group holding a mask rectangle, so a
// drawing of ten shapes opened as ten nested groups and twenty paths, none of
// which anyone drew.

private func board(_ w: CGFloat = 400, _ h: CGFloat = 400, containing kids: [Layer]) -> Page {
    var b = Layer(kind: .group(kids))
    b.isArtboard = true
    b.frame = CGRect(x: 0, y: 0, width: w, height: h)
    b.name = "Artboard"
    var p = Page(name: "t")
    p.layers = [ b ]
    return p
}

private func shape(_ rect: CGRect, stroke: CGFloat = 0) -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), closed: true))
    l.frame = rect
    if stroke > 0 {
        var b = Border()
        b.thickness = stroke
        l.style.borders = [ b ]
    } else {
        l.style.fills = [ Fill(paint: .color(.black)) ]
    }
    return l
}

@Test func aShapeWellInsideItsBoardExportsWithNoClip() {
    let svg = SVGWriter().svg(page: board(containing: [ shape(CGRect(x: 50, y: 50, width: 100, height: 100)) ]))
    #expect(!svg.contains("clip-path"), "a clip that cuts nothing became a Clipped group")
    #expect(!svg.contains("clipPath"))
    #expect(svg.contains("<path"), "the shape itself must still be there")
}

@Test func aShapeHangingOffTheBoardKeepsItsClip() {
    // The case the clipping is FOR. Dropping this would change the picture.
    let svg = SVGWriter().svg(page: board(containing: [ shape(CGRect(x: 300, y: 50, width: 400, height: 100)) ]))
    #expect(svg.contains("clip-path"), "art overflowing the board must still be cut")
}

@Test func aStrokeThatReachesPastTheEdgeKeepsItsClip() {
    // The shape's own outline is inside; half its stroke is not.
    let svg = SVGWriter().svg(page: board(containing: [ shape(CGRect(x: 2, y: 50, width: 100, height: 100), stroke: 20) ]))
    #expect(svg.contains("clip-path"), "ink past the edge is exactly what the board cuts")
}

@Test func aStrokeThatStaysInsideDoesNot() {
    let svg = SVGWriter().svg(page: board(containing: [ shape(CGRect(x: 60, y: 60, width: 100, height: 100), stroke: 20) ]))
    #expect(!svg.contains("clip-path"))
}

@Test func aShadowReachingPastTheEdgeKeepsItsClip() {
    var l = shape(CGRect(x: 6, y: 50, width: 100, height: 100))
    var s = Shadow()
    s.blur = 30
    s.offset = CGSize(width: -20, height: 0)
    l.style.shadows = [ s ]
    let svg = SVGWriter().svg(page: board(containing: [ l ]))
    #expect(svg.contains("clip-path"))
}

@Test func aShapedMaskIsNeverDropped() {
    // A circular mask cuts a square that sits entirely inside its bounding box,
    // so containment alone can't be the test.
    var circle = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 200), transform: nil), closed: true))
    circle.frame = CGRect(x: 100, y: 100, width: 200, height: 200)
    circle.hasClippingMask = true
    circle.style.fills = [ Fill(paint: .color(.black)) ]
    let inside = shape(CGRect(x: 120, y: 120, width: 160, height: 160))
    var g = Layer(kind: .group([ circle, inside ]))
    g.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
    let svg = SVGWriter().svg(page: board(containing: [ g ]))
    #expect(svg.contains("clip-path"), "a shaped mask must survive")
}

@Test func severalTidyShapesProduceNoDefsAtAll() {
    // The actual complaint: one drawing, a pile of Clipped groups.
    let kids = (0..<8).map { shape(CGRect(x: 20 + CGFloat($0) * 40, y: 40, width: 30, height: 30)) }
    let svg = SVGWriter().svg(page: board(containing: kids))
    #expect(!svg.contains("clipPath"))
    #expect(svg.components(separatedBy: "<path").count - 1 == 8, "one path per shape and nothing else")
}

@Test func aBoardAwayFromTheOriginIsAlsoTidied() {
    // The case that matters most: AI Draw puts its copy at x + width + 10, so
    // the board's clip rect arrives translated. If the "is it a rectangle" test
    // only recognised a rect built at the origin, this whole fix would quietly
    // do nothing for every board except the first.
    var b = Layer(kind: .group([ shape(CGRect(x: 50, y: 50, width: 100, height: 100)) ]))
    b.isArtboard = true
    b.frame = CGRect(x: 410, y: 0, width: 400, height: 400)
    var p = Page(name: "t")
    p.layers = [ b ]
    let svg = SVGWriter().svg(page: p)
    #expect(!svg.contains("clip-path"), "a translated board's clip was kept")
}

@Test func aKeptClipIsWrittenWhereTheArtIs() {
    // A board far down the canvas, with art hanging off it so the clip survives.
    // The clip arrives in canvas coordinates and everything else gets shifted to
    // 0,0, so an unshifted clip sits a thousand points below the viewBox and cuts
    // the whole drawing away. The file opens blank with nothing reporting a problem.
    var b = Layer(kind: .group([ shape(CGRect(x: 300, y: 50, width: 400, height: 100)) ]))
    b.isArtboard = true
    b.frame = CGRect(x: 100, y: 1030, width: 400, height: 400)
    var p = Page(name: "t")
    p.layers = [ b ]
    let svg = SVGWriter().svg(page: p)

    #expect(svg.contains("clip-path"), "art overflowing the board must still be cut")
    let d = svg.components(separatedBy: "<clipPath")[1]
        .components(separatedBy: "<path d=\"")[1]
        .components(separatedBy: "\"")[0]
    let numbers = String(d.map { "MLZ".contains($0) ? " " : $0 })
        .split(separator: " ").compactMap { Double($0) }
    #expect(numbers.allSatisfy { $0 >= -1 && $0 <= 401 },
            "the clip kept its canvas position and now misses the viewBox: \(d)")
}

@Test func twoBoardsSideBySideBothComeOutClean() {
    // What the drawn-beside-original layout actually produces.
    func made(_ x: CGFloat) -> Layer {
        var b = Layer(kind: .group([ shape(CGRect(x: 40, y: 40, width: 120, height: 120)) ]))
        b.isArtboard = true
        b.frame = CGRect(x: x, y: 0, width: 400, height: 400)
        return b
    }
    var p = Page(name: "t")
    p.layers = [ made(0), made(410) ]
    let svg = SVGWriter().svg(page: p)
    #expect(!svg.contains("clipPath"))
}
