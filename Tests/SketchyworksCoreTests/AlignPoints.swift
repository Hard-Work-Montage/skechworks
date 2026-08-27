import CoreGraphics
import Foundation
import Testing
@testable import SketchyworksCore

// The six alignment buttons, aimed at picked points instead of whole layers.

/// A ragged four-point open path. Nothing lines up with anything.
private func ragged() -> VectorPath {
    VectorPath(points: [
        VectorPoint(CGPoint(x: 10, y: 100)),
        VectorPoint(CGPoint(x: 40, y: 20)),
        VectorPoint(CGPoint(x: 70, y: 60)),
        VectorPoint(CGPoint(x: 95, y: 5)),
    ])
}

@Test func leftUsesTheLeftmostPickedPointNotTheShape() {
    var p = ragged()
    p.align([1, 2, 3], to: .left)
    // 40 is the leftmost of the three chosen, not 10 — point 0 was not picked
    // and must not drag the others out to meet it.
    #expect(p.points[1].point.x == 40)
    #expect(p.points[2].point.x == 40)
    #expect(p.points[3].point.x == 40)
    #expect(p.points[0].point.x == 10, "an unpicked point stays exactly where it was")
}

@Test func topAndBottomTakeTheExtremesOfTheSelection() {
    var top = ragged()
    top.align([0, 1, 2], to: .top)
    #expect(top.points.prefix(3).allSatisfy { $0.point.y == 20 })

    var bottom = ragged()
    bottom.align([0, 1, 2], to: .bottom)
    #expect(bottom.points.prefix(3).allSatisfy { $0.point.y == 100 })
}

@Test func centringSitsHalfwayBetweenTheOutermostPicked() {
    var p = ragged()
    p.align([0, 3], to: .horizontalCentre)      // 10 and 95
    #expect(p.points[0].point.x == 52.5)
    #expect(p.points[3].point.x == 52.5)

    var v = ragged()
    v.align([1, 3], to: .verticalMiddle)        // 20 and 5
    #expect(v.points[1].point.y == 12.5)
    #expect(v.points[3].point.y == 12.5)
}

@Test func alignAcrossOneAxisLeavesTheOtherAlone() {
    var p = ragged()
    let ys = p.points.map(\.point.y)
    p.align([0, 1, 2, 3], to: .left)
    #expect(p.points.map(\.point.y) == ys)
}

@Test func handlesTravelWithTheirAnchorSoCurvesKeepTheirShape() {
    func curved(_ at: CGPoint, _ from: CGPoint, _ to: CGPoint) -> VectorPoint {
        var v = VectorPoint(at)
        v.curveFrom = from; v.curveTo = to
        v.hasCurveFrom = true; v.hasCurveTo = true
        v.mode = .asymmetric
        return v
    }
    var p = VectorPath(points: [
        curved(CGPoint(x: 0, y: 0), CGPoint(x: 20, y: -10), CGPoint(x: -20, y: 10)),
        curved(CGPoint(x: 100, y: 50), CGPoint(x: 120, y: 40), CGPoint(x: 80, y: 60)),
    ])
    p.align([0, 1], to: .top)                   // both move to y = 0

    // The handle offsets are what give a segment its curve. Snapping anchors and
    // leaving handles behind would silently reshape the curve on every align.
    #expect(p.points[1].point == CGPoint(x: 100, y: 0))
    #expect(p.points[1].curveFrom == CGPoint(x: 120, y: -10))
    #expect(p.points[1].curveTo == CGPoint(x: 80, y: 10))
    #expect(p.points[0].curveFrom == CGPoint(x: 20, y: -10), "an already-aligned point does not drift")
}

@Test func onePointOrNoneIsLeftUntouched() {
    let original = ragged()
    for picks in [[], [2]] {
        var p = original
        p.align(picks, to: .left)
        #expect(p.points.map(\.point) == original.points.map(\.point),
                "aligning one point to itself is not a change worth an undo step")
    }
}

@Test func outOfRangeIndicesAreIgnoredRatherThanCrashing() {
    var p = ragged()
    p.align([1, 2, 99, -3], to: .left)
    #expect(p.points[1].point.x == 40)
    #expect(p.points[2].point.x == 40)
}
