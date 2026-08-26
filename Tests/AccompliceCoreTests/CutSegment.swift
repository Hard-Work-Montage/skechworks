import CoreGraphics
import Foundation
import Testing
@testable import AccompliceCore

// The scissors: one segment out of a path.

/// A closed square, corners in reading order.
private func square() -> VectorPath {
    VectorPath(points: [
        VectorPoint(CGPoint(x: 0, y: 0)),
        VectorPoint(CGPoint(x: 100, y: 0)),
        VectorPoint(CGPoint(x: 100, y: 100)),
        VectorPoint(CGPoint(x: 0, y: 100)),
    ], closed: true)
}

/// A four-point open zigzag.
private func zigzag() -> VectorPath {
    VectorPath(points: [
        VectorPoint(CGPoint(x: 0, y: 0)),
        VectorPoint(CGPoint(x: 30, y: 40)),
        VectorPoint(CGPoint(x: 60, y: 0)),
        VectorPoint(CGPoint(x: 90, y: 40)),
    ])
}

@Test func cuttingAClosedPathOpensItAtTheCut() {
    var p = square()
    let other = p.cut(segment: 1)      // the right-hand edge, (100,0) → (100,100)
    #expect(other == nil, "a closed path opens; it never splits")
    #expect(!p.closed)
    #expect(p.points.count == 4, "no point is lost, only the join between two of them")
    // The far side of the cut is now the start, so the two ends are the anchors
    // that used to be joined.
    #expect(p.points.first?.point == CGPoint(x: 100, y: 100))
    #expect(p.points.last?.point == CGPoint(x: 100, y: 0))
    #expect(p.segmentCount == 3)
}

@Test func cuttingTheClosingSegmentKeepsTheOrder() {
    var p = square()
    p.cut(segment: 3)                  // (0,100) → (0,0), the one closeSubpath draws
    #expect(!p.closed)
    #expect(p.points.map(\.point) == square().points.map(\.point))
}

@Test func cuttingTheMiddleOfAnOpenPathSplitsItInTwo() {
    var p = zigzag()
    let tail = p.cut(segment: 1)
    #expect(p.points.map(\.point) == [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 40)])
    #expect(tail?.points.map(\.point) == [CGPoint(x: 60, y: 0), CGPoint(x: 90, y: 40)])
    #expect(tail?.closed == false)
}

@Test func cuttingAnEndSegmentJustDropsTheEndPoint() {
    var first = zigzag()
    #expect(first.cut(segment: 0) == nil)
    #expect(first.points.map(\.point) == Array(zigzag().points.map(\.point).dropFirst()))

    var last = zigzag()
    #expect(last.cut(segment: 2) == nil)
    #expect(last.points.map(\.point) == Array(zigzag().points.map(\.point).dropLast()))
}

@Test func aBareLineCannotBeCut() {
    var line = VectorPath(points: [VectorPoint(.zero), VectorPoint(CGPoint(x: 10, y: 0))])
    #expect(!line.canCut(segment: 0))
    #expect(line.cut(segment: 0) == nil)
    #expect(line.points.count == 2, "refusing means leaving it alone")
    #expect(square().canCut(segment: 0), "a closed two-pointer opens into a line, which is fine")
}

@Test func theHandlesAcrossTheCutGoWithIt() {
    var p = square()
    // Curve every corner so both anchors at the cut carry a pair of handles.
    for i in p.points.indices {
        let prev = p.points[(i + 3) % 4].point, next = p.points[(i + 1) % 4].point
        p.points[i].convert(to: .mirrored, previous: prev, next: next)
    }
    p.cut(segment: 1)
    let start = p.points.first!, end = p.points.last!
    #expect(!start.hasCurveTo, "the new start has nothing behind it to lead in from")
    #expect(start.hasCurveFrom, "…but still shapes the segment it leads into")
    #expect(!end.hasCurveFrom)
    #expect(end.hasCurveTo)
    #expect(start.mode == .disconnected && end.mode == .disconnected,
            "one handle left means free, or dragging it would grow the other back")
    #expect(p.points[1].mode == .mirrored, "anchors away from the cut are untouched")
}

@Test func cornerRadiiRideAlongThroughACut() {
    var p = square()
    p.points[2].cornerRadius = 12
    p.cut(segment: 0)
    // (100,100) was index 2; after opening at segment 0 the start is (100,0), so it's index 1.
    #expect(p.points[1].point == CGPoint(x: 100, y: 100))
    #expect(p.points[1].cornerRadius == 12)
}
