import CoreGraphics
import Testing

@testable import SkechworksCore

// Moving a point moves it the way you moved it.
//
// Editing a path renormalises it to start at the origin and lets the frame
// absorb the difference. Adding that difference to the frame origin is right
// only for a layer with no flip and no rotation. A flip mirrors the path about
// the frame's CENTRE, so moving the frame moves the mirror too, and on a
// flipped shape the two cancel: drag the outermost point right and it lands
// back where it started.
//
// So these don't test the frame arithmetic. They test the thing the arithmetic
// is for: where the point ends up on the page.

private func square() -> Layer {
    let path = CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 60), transform: nil)
    var l = Layer(kind: .path(path, closed: true))
    l.frame = CGRect(x: 200, y: 300, width: 100, height: 60)
    return l
}

/// Renormalise an edited path onto the layer the way commitEditedPath does.
private func commit(_ l: inout Layer, edited: CGPath) {
    let box = edited.boundingBoxOfPath
    l.frame = Compose.reframed(l, localBounds: box)
    l.kind = .path(edited.transformed(by: CGAffineTransform(translationX: -box.minX,
                                                            y: -box.minY)), closed: true)
}

/// Every corner of the layer's shape, in the page's coordinates.
private func onPage(_ l: Layer) -> [CGPoint] {
    guard let p = Compose.resolvedPath(l) else { return [] }
    var out: [CGPoint] = []
    p.transformed(by: Compose.transform(l)).applyWithBlock { e in
        let kind = e.pointee.type
        if kind == .moveToPoint || kind == .addLineToPoint { out.append(e.pointee.points[0]) }
    }
    return out
}

/// Drags the leftmost-on-page points by `dx`, in the layer's own coordinates.
private func dragLeftEdge(_ l: Layer, dx: CGFloat) -> CGPath {
    guard let local = Compose.resolvedPath(l) else { return CGPath(rect: .zero, transform: nil) }
    let toPage = Compose.transform(l)
    let leftOnPage = onPage(l).map(\.x).min() ?? 0
    let edited = CGMutablePath()
    var first = true
    local.applyWithBlock { e in
        guard e.pointee.type == .moveToPoint || e.pointee.type == .addLineToPoint else { return }
        var p = e.pointee.points[0]
        // Whether this point is on the left edge is a question about the page,
        // not about the path — that is the whole point of the bug.
        if abs(p.applying(toPage).x - leftOnPage) < 0.01 {
            // Move it right ON PAGE by dx, which may be -dx locally.
            let want = CGPoint(x: p.applying(toPage).x + dx, y: p.applying(toPage).y)
            p = want.applying(toPage.inverted())
        }
        if first { edited.move(to: p); first = false } else { edited.addLine(to: p) }
    }
    edited.closeSubpath()
    return edited
}

@Test func draggingRightOnAPlainShapeGoesRight() {
    var l = square()
    let before = onPage(l).map(\.x).min()!
    commit(&l, edited: dragLeftEdge(l, dx: 10))
    #expect(abs(onPage(l).map(\.x).min()! - (before + 10)) < 0.01)
}

@Test func draggingRightOnAFlippedShapeAlsoGoesRight() {
    var l = square()
    l.flipH = true
    let before = onPage(l).map(\.x).min()!
    commit(&l, edited: dragLeftEdge(l, dx: 10))
    // Naive frame arithmetic lands this back on `before` exactly.
    #expect(abs(onPage(l).map(\.x).min()! - (before + 10)) < 0.01)
}

@Test func theRestOfAFlippedShapeStaysPut() {
    var l = square()
    l.flipH = true
    let rightBefore = onPage(l).map(\.x).max()!
    let topBefore = onPage(l).map(\.y).min()!
    commit(&l, edited: dragLeftEdge(l, dx: 10))
    #expect(abs(onPage(l).map(\.x).max()! - rightBefore) < 0.01)
    #expect(abs(onPage(l).map(\.y).min()! - topBefore) < 0.01)
}

@Test func aVerticallyFlippedShapeMovesTheWayItIsDragged() {
    var l = square()
    l.flipV = true
    let before = onPage(l).map(\.x).min()!
    commit(&l, edited: dragLeftEdge(l, dx: 10))
    #expect(abs(onPage(l).map(\.x).min()! - (before + 10)) < 0.01)
}

@Test func aShapeFlippedBothWaysMovesTheWayItIsDragged() {
    var l = square()
    l.flipH = true
    l.flipV = true
    let before = onPage(l).map(\.x).min()!
    commit(&l, edited: dragLeftEdge(l, dx: 10))
    #expect(abs(onPage(l).map(\.x).min()! - (before + 10)) < 0.01)
}

@Test func aRotatedShapeMovesTheWayItIsDragged() {
    var l = square()
    l.rotation = 30
    let before = onPage(l).map(\.x).min()!
    commit(&l, edited: dragLeftEdge(l, dx: 10))
    #expect(abs(onPage(l).map(\.x).min()! - (before + 10)) < 0.01)
}

@Test func aRotatedAndFlippedShapeMovesTheWayItIsDragged() {
    var l = square()
    l.rotation = 30
    l.flipH = true
    let before = onPage(l).map(\.x).min()!
    commit(&l, edited: dragLeftEdge(l, dx: 10))
    #expect(abs(onPage(l).map(\.x).min()! - (before + 10)) < 0.01)
}

@Test func anUntouchedShapeIsLeftExactlyWhereItWas() {
    for (name, build) in [("plain", { square() }),
                          ("flipped", { var l = square(); l.flipH = true; return l }),
                          ("rotated", { var l = square(); l.rotation = 30; return l })] {
        var l = build()
        let before = onPage(l)
        commit(&l, edited: Compose.resolvedPath(l)!)
        let after = onPage(l)
        #expect(before.count == after.count, "\(name)")
        for (a, b) in zip(before, after) {
            #expect(abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01, "\(name)")
        }
    }
}
