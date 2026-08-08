import CoreGraphics
import Testing

@testable import AccompliceCore

// Perspective on a path.
//
// The point of the whole exercise is the one thing skew cannot do: make one
// side shorter than the other. A shear takes a rectangle to a parallelogram
// and nowhere else, so if these tests only checked "the shape changed" they
// would pass against the skew that already existed.

private func square(_ f: CGRect = CGRect(x: 100, y: 100, width: 200, height: 100)) -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(origin: .zero, size: f.size), transform: nil),
                              closed: true))
    l.frame = f
    return l
}

/// A quad where the left edge is pulled in from top and bottom: the near/far
/// look Adam asked for, small on the left and full height on the right.
private let leaningQuad = [CGPoint(x: 0, y: 0.25), CGPoint(x: 1, y: 0),
                           CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 0.75)]

private func points(_ l: Layer) -> [CGPoint] {
    var out: [CGPoint] = []
    Compose.resolvedPath(l)?.applyWithBlock { e in
        switch e.pointee.type {
        case .moveToPoint, .addLineToPoint: out.append(e.pointee.points[0])
        case .addCurveToPoint: out.append(e.pointee.points[2])
        default: break
        }
    }
    return out
}

@Test func theUnitSquareMapsToTheQuadItWasGiven() {
    let project = try! #require(Perspective.map(toUnitQuad: leaningQuad))
    let sent = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(project)
    for (got, want) in zip(sent, leaningQuad) {
        #expect(abs(got.x - want.x) < 1e-6 && abs(got.y - want.y) < 1e-6)
    }
}

@Test func anIdentityQuadChangesNothing() {
    let project = try! #require(Perspective.map(toUnitQuad: [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]))
    for p in [CGPoint(x: 0.3, y: 0.7), CGPoint(x: 0.9, y: 0.1)] {
        let out = project(p)
        #expect(abs(out.x - p.x) < 1e-9 && abs(out.y - p.y) < 1e-9)
    }
}

@Test func oneSideComesOutShorterThanTheOther() {
    var l = square()
    let warped = l.applyPerspective(corners: leaningQuad)
    #expect(warped)

    let p = points(l)
    let leftHeight = p.filter { $0.x < 1 }.map(\.y)
    let rightHeight = p.filter { $0.x > l.frame.width - 1 }.map(\.y)
    let left = (leftHeight.max() ?? 0) - (leftHeight.min() ?? 0)
    let right = (rightHeight.max() ?? 0) - (rightHeight.min() ?? 0)

    // Half the height on the left, full on the right. No shear can do this.
    #expect(left < right * 0.6, "left \(left) right \(right)")
}

@Test func aDegenerateQuadIsRefusedRatherThanExploding() {
    // Three corners in a line: no inverse, no meaning.
    #expect(Perspective.map(toUnitQuad: [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0),
                                         CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]) == nil)
    var l = square()
    let before = l.frame
    let refused = l.applyPerspective(corners: [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0),
                                               CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)])
    #expect(!refused)
    #expect(l.frame == before)
}

@Test func straightEdgesStayStraight() {
    // A homography takes lines to lines exactly, so a rectangle comes back as
    // four straight edges and not as a fan of little ones. Subdividing is only
    // for curves; paying it on a line would bloat every warped rectangle.
    var l = square()
    let warped = l.applyPerspective(corners: leaningQuad)
    #expect(warped)

    var lines = 0, curves = 0
    Compose.resolvedPath(l)?.applyWithBlock { e in
        if e.pointee.type == .addLineToPoint { lines += 1 }
        if e.pointee.type == .addCurveToPoint { curves += 1 }
    }
    #expect(curves == 0)
    #expect(lines <= 4, "a straight edge came back in \(lines) pieces")
}

@Test func aBitmapIsLeftAlone() {
    var l = Layer(kind: .bitmap(imageRef: "images/x.png"))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    // Pictures already distort properly, as a lens rather than a bake.
    let refused = l.applyPerspective(corners: leaningQuad)
    #expect(!refused)
}

@Test func curvesSurviveAsCurves() {
    var l = square()
    l.kind = .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 100), transform: nil),
                   closed: true)
    let warped = l.applyPerspective(corners: leaningQuad)
    #expect(warped)

    var curves = 0, lines = 0
    Compose.resolvedPath(l)?.applyWithBlock { e in
        if e.pointee.type == .addCurveToPoint { curves += 1 }
        if e.pointee.type == .addLineToPoint { lines += 1 }
    }
    // Chopped, not flattened: an oval comes back as curves, not a polygon.
    #expect(curves > 0)
    #expect(lines == 0)
}

@Test func aWarpedShapeStaysWhereItWas() {
    var l = square()
    let before = l.frame
    let warped = l.applyPerspective(corners: leaningQuad)
    #expect(warped)
    // The quad's right edge is untouched, so the shape's right edge shouldn't
    // wander off. Its left comes in, so the box narrows in height only.
    #expect(abs(l.frame.maxX - before.maxX) < 0.5)
    #expect(abs(l.frame.minX - before.minX) < 0.5)
}

@Test func aFlippedShapeDoesNotJumpWhenItIsWarped() {
    var l = square()
    l.flipH = true
    let rightBefore = Compose.resolvedPath(l)!.transformed(by: Compose.transform(l))
        .boundingBoxOfPath.maxX
    let warped = l.applyPerspective(corners: leaningQuad)
    #expect(warped)
    let rightAfter = Compose.resolvedPath(l)!.transformed(by: Compose.transform(l))
        .boundingBoxOfPath.maxX
    #expect(abs(rightBefore - rightAfter) < 0.5)
}

@Test func warpingFromTheSameStartTwiceGivesTheSameShape() {
    // What the drag relies on. Each frame restores the original geometry and
    // warps it afresh; if that weren't idempotent the shape would curl further
    // in on itself the longer you held the mouse down.
    let base = Compose.resolvedPath(square())!
    let start = square().frame

    var once = square()
    once.kind = .path(base, closed: true)
    once.frame = start
    _ = once.applyPerspective(corners: leaningQuad)

    var twice = square()
    twice.kind = .path(base, closed: true)
    twice.frame = start
    _ = twice.applyPerspective(corners: leaningQuad)
    // Second frame of the drag: back to the original, then warped again.
    twice.kind = .path(base, closed: true)
    twice.frame = start
    _ = twice.applyPerspective(corners: leaningQuad)

    #expect(once.frame == twice.frame)
    #expect(points(once).count == points(twice).count)
    for (a, b) in zip(points(once), points(twice)) {
        #expect(abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6)
    }
}

@Test func warpingTheSameShapeAgainWithoutRestartingCompounds() {
    // The failure the drag is written to avoid, pinned so nobody "simplifies"
    // the base-path bookkeeping away later.
    var l = square()
    _ = l.applyPerspective(corners: leaningQuad)
    let after = points(l)
    _ = l.applyPerspective(corners: leaningQuad)
    let twice = points(l)
    // The frame is no use as a witness here: this quad leaves the bounding box
    // exactly where it was, so only the geometry inside it tells the truth.
    let moved = zip(after, twice).contains { abs($0.y - $1.y) > 1 }
    #expect(moved, "warping twice should compound — the drag must restore first")
}

@Test func anOpenPathStaysOpen() {
    let line = CGMutablePath()
    line.move(to: CGPoint(x: 0, y: 0))
    line.addLine(to: CGPoint(x: 200, y: 100))
    var l = square()
    l.kind = .path(line, closed: false)
    let warped = l.applyPerspective(corners: leaningQuad)
    #expect(warped)
    guard case .path(_, let closed) = l.kind else { Issue.record("not a path"); return }
    #expect(!closed)
}

@Test func aGentleWarpCostsFewSegments() {
    // The point of splitting only where the projection needs it. A fixed twelve
    // pieces per curve turned this oval into 48 segments however lightly it was
    // leaned, and a warped shape you then have to go and Simplify is a warped
    // shape that cost too much.
    var l = square()
    l.kind = .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 100), transform: nil),
                   closed: true)
    let gentle = [CGPoint(x: 0, y: 0.08), CGPoint(x: 1, y: 0),
                  CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 0.92)]
    let warped = l.applyPerspective(corners: gentle)
    #expect(warped)

    var segments = 0
    Compose.resolvedPath(l)?.applyWithBlock { e in
        if e.pointee.type == .addCurveToPoint { segments += 1 }
    }
    #expect(segments <= 16, "a gentle lean cost \(segments) segments")
}

@Test func aHarderWarpSpendsMoreThanAGentleOne() {
    func segments(_ quad: [CGPoint]) -> Int {
        var l = square()
        l.kind = .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 100),
                              transform: nil), closed: true)
        _ = l.applyPerspective(corners: quad)
        var n = 0
        Compose.resolvedPath(l)?.applyWithBlock { e in
            if e.pointee.type == .addCurveToPoint { n += 1 }
        }
        return n
    }
    let gentle = segments([CGPoint(x: 0, y: 0.08), CGPoint(x: 1, y: 0),
                           CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 0.92)])
    let severe = segments([CGPoint(x: 0, y: 0.45), CGPoint(x: 1.1, y: -0.1),
                           CGPoint(x: 1.1, y: 1.1), CGPoint(x: 0, y: 0.55)])
    // Adaptive means the cost follows the work. Equal counts would mean the
    // budget is being ignored in one direction or the other.
    #expect(severe > gentle, "gentle \(gentle) severe \(severe)")
}

@Test func aWarpedShapeCanBeSimplifiedFurther() {
    // Simplify is the escape hatch when even the adaptive count is more than a
    // drawing needs. It has to still work on a warped shape.
    var l = square()
    l.kind = .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 100), transform: nil),
                   closed: true)
    _ = l.applyPerspective(corners: leaningQuad)
    guard case .path(let warped, _) = l.kind else { Issue.record("not a path"); return }

    var vp = VectorPath(cgPath: warped)
    let before = vp.points.count
    vp.simplify(tolerance: 1)
    #expect(vp.points.count < before, "simplify left \(vp.points.count) of \(before)")
}

@Test func warpingTheSameShapeOverAndOverDoesNotGrowIt() {
    // The bug that ate a comic. Chopping every curve a fixed twelve times meant
    // each fresh drag started from the already-chopped path, so four warps of a
    // 261-curve union came to 261 x 12^4 — 5.4 million segments and 217MB of
    // path text in a saved file that then took forever to write.
    //
    // Splitting only where the projection needs it settles instead of
    // multiplying: a piece that is already fine passes the check untouched.
    let many = CGMutablePath()
    for i in 0..<40 { many.addEllipse(in: CGRect(x: CGFloat(i) * 7, y: 0, width: 30, height: 20)) }
    var l = Layer(kind: .path(many, closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 320, height: 60)

    func segments(_ l: Layer) -> Int {
        var n = 0
        Compose.resolvedPath(l)?.applyWithBlock { e in
            if e.pointee.type == .addCurveToPoint { n += 1 }
        }
        return n
    }
    let quad = [CGPoint(x: 0, y: 0.15), CGPoint(x: 1, y: 0),
                CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 0.85)]
    _ = l.applyPerspective(corners: quad)
    let once = segments(l)
    for _ in 0..<4 { _ = l.applyPerspective(corners: quad) }
    let fiveTimes = segments(l)

    // Under the old fixed twelve this would be `once` x 12^4.
    #expect(fiveTimes <= once * 2, "one warp \(once), five warps \(fiveTimes)")
}

@Test func aWarpThatWouldExplodeIsRefused() {
    // The backstop. A refusal has to leave the shape alone rather than half-warp
    // it, so the layer is compared before and after.
    let path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)
    // A tolerance of zero can never be met, so every curve splits to maxDepth.
    let out = Perspective.warp(path, size: CGSize(width: 100, height: 100),
                               corners: leaningQuad, tolerance: 0)
    // maxDepth caps this one well under the ceiling, so it still succeeds —
    // the ceiling is for a route that bypasses the depth cap.
    #expect(out != nil)
    #expect(Perspective.segmentCeiling > 0)
}
