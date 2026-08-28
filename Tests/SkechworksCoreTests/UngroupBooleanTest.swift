import CoreGraphics
import Testing

@testable import SkechworksCore

// Union and Subtract come apart again.
//
// They're groups with a rule attached, and ungroup only accepted plain groups —
// so the menu item was there, did nothing, and said nothing. A subtract you
// wanted to adjust was one you had to undo your way back out of.

private func shape(_ r: CGRect, _ name: String) -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(origin: .zero, size: r.size), transform: nil), closed: true))
    l.frame = r
    l.name = name
    return l
}

private func boolean(_ rule: WindingRule = .nonZero, at origin: CGPoint = .zero,
                     _ kids: [Layer]) -> Page {
    var g = Layer(kind: .shapeGroup(kids, rule))
    g.frame = CGRect(origin: origin, size: CGSize(width: 200, height: 200))
    g.name = "Subtract"
    g.style.fills = [Fill(paint: .color(.black))]
    var p = Page(name: "t")
    p.layers = [g]
    return p
}

@Test func aBooleanGroupComesApart() {
    var p = boolean(.nonZero, [ shape(CGRect(x: 0, y: 0, width: 100, height: 100), "Big"),
                                shape(CGRect(x: 20, y: 20, width: 40, height: 40), "Hole") ])
    let freed = p.ungroup(p.layers[0].id)
    #expect(freed.count == 2, "ungroup did nothing")
    #expect(p.layers.count == 2)
    #expect(p.layers.map(\.name) == [ "Big", "Hole" ])
}

@Test func theFreedShapesLandWhereTheyLooked() {
    // Members are stored relative to the group, so releasing them without
    // adding its origin drops them in the corner of the page.
    var p = boolean(.nonZero, at: CGPoint(x: 300, y: 100),
                    [ shape(CGRect(x: 10, y: 20, width: 50, height: 50), "One") ])
    _ = p.ungroup(p.layers[0].id)
    #expect(p.layers[0].frame.origin == CGPoint(x: 310, y: 120))
}

@Test func theFreedShapesAreStillVisible() {
    // A boolean paints the combined shape, so its members often have no fill of
    // their own. Released as they stand they come back invisible, which looks
    // exactly like Ungroup having deleted them.
    var p = boolean(.nonZero, [ shape(CGRect(x: 0, y: 0, width: 100, height: 100), "Big") ])
    #expect(p.layers[0].style.fills.count == 1)
    _ = p.ungroup(p.layers[0].id)
    #expect(!p.layers[0].style.fills.isEmpty, "the freed shape has nothing to paint it")
}

@Test func aShapeWithItsOwnColourKeepsIt() {
    var member = shape(CGRect(x: 0, y: 0, width: 100, height: 100), "Red")
    member.style.fills = [Fill(paint: .color(Color(r: 1, g: 0, b: 0, a: 1)))]
    var p = boolean(.nonZero, [ member ])
    _ = p.ungroup(p.layers[0].id)
    if case .color(let c)? = p.layers[0].style.fills.first?.paint {
        #expect(c.hex == "#ff0000", "the group's colour overwrote the shape's own")
    }
}

@Test func aBooleanNestedInsideAnotherComesApartToo() {
    // Exactly Adam's layer list: a Union living inside a Subtract.
    var inner = Layer(kind: .shapeGroup([ shape(CGRect(x: 0, y: 0, width: 50, height: 50), "A"),
                                          shape(CGRect(x: 10, y: 10, width: 50, height: 50), "B") ],
                                        .nonZero))
    inner.frame = CGRect(x: 5, y: 5, width: 60, height: 60)
    inner.name = "Union"
    var p = boolean(.nonZero, [ inner, shape(CGRect(x: 0, y: 0, width: 20, height: 20), "Ellipse") ])
    let freed = p.ungroup(inner.id)
    #expect(freed.count == 2, "the nested Union didn't come apart")
    guard case .shapeGroup(let kids, _) = p.layers[0].kind else { Issue.record("outer changed shape"); return }
    #expect(kids.map(\.name) == [ "A", "B", "Ellipse" ])
}

@Test func aPlainGroupStillUngroupsAsBefore() {
    var g = Layer(kind: .group([ shape(CGRect(x: 1, y: 2, width: 10, height: 10), "Kid") ]))
    g.frame = CGRect(x: 100, y: 100, width: 50, height: 50)
    var p = Page(name: "t")
    p.layers = [g]
    _ = p.ungroup(g.id)
    #expect(p.layers.count == 1)
    #expect(p.layers[0].frame.origin == CGPoint(x: 101, y: 102))
}
