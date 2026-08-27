import CoreGraphics
import Foundation
import Testing
@testable import SketchyworksCore

// A path of several outlines: a letter with a hole, a trace full of islands.

/// A square with a square hole, both closed.
private func ring() -> CGPath {
    let m = CGMutablePath()
    m.addRect(CGRect(x: 0, y: 0, width: 100, height: 100))
    m.addRect(CGRect(x: 30, y: 30, width: 40, height: 40))
    return m.copy()!
}

@Test func outlinesAreReadApartAndWrittenBackApart() {
    let vp = VectorPath(cgPath: ring())
    #expect(vp.closed)
    #expect(vp.points.count == 8)
    #expect(vp.subpathStarts == [0, 4])
    #expect(vp.isCompound)
    // The rebuilt path is the ring, not one chain wandering through both squares.
    #expect(SVGWriter().pathData(vp.cgPath()) == SVGWriter().pathData(ring()))
}

@Test func noSegmentJoinsOneOutlineToTheNext() {
    let vp = VectorPath(cgPath: ring())
    // Segment 3 leaves the outer square's last corner and comes home, not
    // across to the hole.
    let (a, b) = vp.segment(3)!
    #expect(vp.next(3) == 0)
    #expect(vp.previous(4) == 7)
    #expect(vp.next(7) == 4)
    #expect(b.point == vp.points[0].point)

    var open = vp
    open.closed = false
    #expect(open.segment(3) == nil, "an open outline ends where it ends")
    #expect(open.next(3) == nil)
    #expect(open.previous(4) == nil)
}

@Test func movingAPointOfOneOutlineLeavesTheOtherAlone() {
    var vp = VectorPath(cgPath: ring())
    vp.points[5].move(to: CGPoint(x: 80, y: 30))
    let back = VectorPath(cgPath: vp.cgPath())
    #expect(back.points.count == 8)
    #expect(back.subpathStarts == [0, 4])
    #expect(back.points[5].point == CGPoint(x: 80, y: 30))
    #expect(back.points[0...3].map(\.point) == vp.points[0...3].map(\.point))
}

@Test func insertingOnTheClosingSegmentStaysInItsOutline() {
    var vp = VectorPath(cgPath: ring())
    let made = vp.insertPoint(onSegment: 3, at: 0.5)!
    #expect(made == 4)
    #expect(vp.points.count == 9)
    #expect(vp.subpathStarts == [0, 5], "the hole still starts where it started")
    #expect(!vp.points[4].startsSubpath)
}

@Test func deletingAnOutlinesFirstPointHandsTheStartOn() {
    var vp = VectorPath(cgPath: ring())
    vp.removePoint(4)
    #expect(vp.points.count == 7)
    #expect(vp.subpathStarts == [0, 4])
    #expect(vp.subpathRanges.map(\.count) == [4, 3])

    var first = VectorPath(cgPath: ring())
    first.removePoint(0)
    #expect(first.subpathStarts == [0, 3])
    #expect(first.subpathRanges.map(\.count) == [3, 4])
}

@Test func cuttingAHoleLetsItGoAsItsOwnOpenPath() {
    var vp = VectorPath(cgPath: ring())
    let gone = vp.cut(segment: 5)
    #expect(vp.closed, "the outer square is still a shape")
    #expect(vp.points.count == 4)
    #expect(!vp.isCompound)
    #expect(gone?.closed == false)
    #expect(gone?.points.count == 4)
    #expect(gone?.points.first?.startsSubpath == false)
}

@Test func simplifyingKeepsTheOutlinesApart() {
    // Two circles, each drawn as a 72-gon.
    let m = CGMutablePath()
    for (cx, r) in [(CGFloat(100), CGFloat(80)), (CGFloat(100), CGFloat(30))] {
        for k in 0..<72 {
            let a = CGFloat(k) / 72 * 2 * .pi
            let pt = CGPoint(x: cx + r * cos(a), y: 100 + r * sin(a))
            if k == 0 { m.move(to: pt) } else { m.addLine(to: pt) }
        }
        m.closeSubpath()
    }
    var vp = VectorPath(cgPath: m)
    #expect(vp.points.count == 144)
    vp.simplify(tolerance: 0.5)
    #expect(vp.points.count < 144)
    #expect(vp.subpathStarts.count == 2)
    let box = vp.cgPath().boundingBoxOfPath
    #expect(abs(box.minX - 20) < 1 && abs(box.maxX - 180) < 1)
}

// Simplify on traced straight edges.

/// A triangle traced as 300 points a pixel or so apart, wobbling half a pixel
/// either side of each edge, the way a bitmap trace hands one back.
private func tracedTriangle() -> VectorPath {
    let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0), CGPoint(x: 150, y: 260)]
    var pts: [VectorPoint] = []
    var seed: UInt32 = 7
    func noise() -> CGFloat { seed = seed &* 1664525 &+ 1013904223; return CGFloat(seed % 100) / 100 - 0.5 }
    for k in 0..<3 {
        let a = corners[k], b = corners[(k + 1) % 3]
        for s in 0..<100 {
            let t = CGFloat(s) / 100
            let nx = -(b.y - a.y), ny = b.x - a.x
            let len = hypot(nx, ny)
            let p = CGPoint(x: a.x + (b.x - a.x) * t + nx / len * noise(),
                            y: a.y + (b.y - a.y) * t + ny / len * noise())
            pts.append(VectorPoint(p))
        }
    }
    return VectorPath(points: pts, closed: true)
}

@Test func aTracedTriangleSimplifiesToThreeStraightCorners() {
    var vp = tracedTriangle()
    #expect(vp.points.count == 300)
    vp.simplify(tolerance: 1.5)
    #expect(vp.points.count == 3, "three corners, nothing else: got \(vp.points.count)")
    #expect(vp.points.allSatisfy { $0.isCorner && $0.mode == .straight }, "straight edges stay straight, no handles")
    #expect(vp.closed)
}

@Test func thinningKeepsRealCornersAndDropsWobble() {
    let line = (0..<50).map { CGPoint(x: CGFloat($0) * 2, y: $0 % 2 == 0 ? 0.3 : -0.3) }
    #expect(VectorPath.thin(line, tolerance: 1, closed: false).count == 2)
    let bent = line + (1..<50).map { CGPoint(x: 98, y: CGFloat($0) * 2) }
    #expect(VectorPath.thin(bent, tolerance: 1, closed: false).count == 3)
}
