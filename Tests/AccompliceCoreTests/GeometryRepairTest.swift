import CoreGraphics
import Testing

@testable import AccompliceCore

// A layer that can't be drawn should say so, not disappear.
//
// Once the change detector stopped crashing on NaN, the failure changed shape
// rather than going away: the layer stays in the list looking present and draws
// nothing at all. That's worse — a shape vanishes off a drawing and whatever
// broke it is long finished and out of sight.

private func shape(_ frame: CGRect) -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    l.frame = frame
    l.name = "stem"
    return l
}

@Test func aNaNFrameIsRepairedAndReported() {
    var l = shape(CGRect(x: 0, y: 0, width: 10, height: 100))
    l.frame.origin.x = .nan
    var p = Page(name: "t")
    p.layers = [ l ]
    let (fixed, broken) = p.repairingGeometry()
    #expect(broken == [ "stem" ], "the layer has to be named, or nobody can chase it")
    #expect(fixed.layers[0].frame.origin.x.isFinite)
}

@Test func aCollapsedSizeIsGivenSomethingToDrawWith() {
    var l = shape(CGRect(x: 0, y: 0, width: 10, height: 100))
    l.frame.size.width = .infinity
    var p = Page(name: "t")
    p.layers = [ l ]
    let (fixed, broken) = p.repairingGeometry()
    #expect(!broken.isEmpty)
    #expect(fixed.layers[0].frame.width.isFinite)
    #expect(fixed.layers[0].frame.width >= 1)
}

@Test func aBadStrokeIsRepairedToo() {
    var l = shape(CGRect(x: 0, y: 0, width: 10, height: 100))
    var b = Border()
    b.thickness = .nan
    l.style.borders = [ b ]
    var p = Page(name: "t")
    p.layers = [ l ]
    let (fixed, broken) = p.repairingGeometry()
    #expect(broken.contains { $0.contains("stroke") })
    #expect(fixed.layers[0].style.borders[0].thickness.isFinite)
}

@Test func somethingBuriedInAGroupIsFoundToo() {
    var bad = shape(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 100))
    var group = Layer(kind: .group([ bad ]))
    group.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    var p = Page(name: "t")
    p.layers = [ group ]
    let (_, broken) = p.repairingGeometry()
    #expect(broken == [ "stem" ])
    _ = bad
}

@Test func aHealthyPageIsLeftExactlyAlone() {
    // It runs on every edit, so it must be a no-op on the normal case — both
    // for speed and because a repair that changes good geometry is a new bug.
    var p = Page(name: "t")
    p.layers = [ shape(CGRect(x: 5, y: 7, width: 11, height: 99)) ]
    let (fixed, broken) = p.repairingGeometry()
    #expect(broken.isEmpty)
    #expect(fixed.layers[0].frame == p.layers[0].frame)
    #expect(fixed.contentSignature == p.contentSignature)
}
