import CoreGraphics
import Testing

@testable import SkechworksCore

// The change detector must never be the thing that loses somebody's drawing.
//
// One layer with a NaN in it turned every subsequent drag into a crash — the
// signature runs on each edit and walks the whole page, so a bad value anywhere
// took down anything you touched, with the work unsaved.

private func shape(_ frame: CGRect) -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(origin: .zero, size: CGSize(width: 10, height: 10)), transform: nil), closed: true))
    l.frame = frame
    return l
}

@Test func aNaNFrameDoesNotCrashTheSignature() {
    var l = shape(CGRect(x: 0, y: 0, width: 10, height: 10))
    l.frame.origin.x = .nan
    var p = Page(name: "t")
    p.layers = [ l ]
    #expect(!p.contentSignature.isEmpty)
}

@Test func anInfiniteStrokeDoesNotCrashTheSignature() {
    var l = shape(CGRect(x: 0, y: 0, width: 10, height: 10))
    var b = Border()
    b.thickness = .infinity
    l.style.borders = [ b ]
    var p = Page(name: "t")
    p.layers = [ l ]
    #expect(!p.contentSignature.isEmpty)
}

@Test func aBadValueBuriedInAGroupIsSurvivedToo() {
    // How it actually happened: a child of a dragged group, not a top-level layer.
    var bad = shape(CGRect(x: 0, y: 0, width: 10, height: 10))
    bad.frame.size.width = .infinity
    var group = Layer(kind: .group([ bad ]))
    group.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    var p = Page(name: "t")
    p.layers = [ group ]
    #expect(!p.contentSignature.isEmpty)
}

@Test func realChangesAreStillNoticed() {
    // Safety must not blunt it: a signature that stops noticing edits throws
    // them away instead of crashing on them, which is worse.
    var p = Page(name: "t")
    p.layers = [ shape(CGRect(x: 0, y: 0, width: 10, height: 10)) ]
    let before = p.contentSignature
    p.layers[0].frame.origin.x += 5
    #expect(p.contentSignature != before)
}

@Test func theModelCannotCreateALayerWithNoRealSize() {
    // The other end: numbers arriving from a model are refused at the door.
    var p = Page(name: "t")
    var spec = AddSpec()
    spec.kind = "path"
    spec.d = "M0 0 L50 50"
    spec.stroke = "#000000"
    spec.strokeWidth = Double.infinity
    _ = p.add(spec)
    if let made = p.layers.last {
        #expect(made.style.borders.first?.thickness.isFinite ?? true)
        #expect(made.frame.width.isFinite)
    }
    #expect(!p.contentSignature.isEmpty)
}

@Test func anAbsurdCoordinateIsIgnoredRatherThanPlaced() {
    var p = Page(name: "t")
    var spec = AddSpec()
    spec.kind = "rect"
    spec.x = 1e300
    spec.y = .nan
    _ = p.add(spec)
    #expect(p.layers.last?.frame.origin.x.isFinite == true)
    #expect(p.layers.last?.frame.origin.y.isFinite == true)
}
