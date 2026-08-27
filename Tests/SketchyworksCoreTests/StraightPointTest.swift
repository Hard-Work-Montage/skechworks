import CoreGraphics
import Testing

@testable import SketchyworksCore

// A straight point has no handles at all.
//
// It said so, and then didn't: every curve segment carries two control points,
// so a straight point sitting next to a curved one contributed its own position
// as one of them. Read back from the path, it came out holding a zero-length
// handle — invisible, exactly on top of the anchor, and first in line for the
// pointer because handles are hit-tested before anchors. The point could be
// seen and not grabbed.

private func curveThenCorner() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: 0))
    // A real curve into a point whose own outgoing control sits on itself.
    p.addCurve(to: CGPoint(x: 100, y: 0), control1: CGPoint(x: 20, y: 40), control2: CGPoint(x: 100, y: 0))
    p.addLine(to: CGPoint(x: 200, y: 0))
    return p
}

@Test func aControlPointOnTopOfItsAnchorIsNotAHandle() {
    let v = VectorPath(cgPath: curveThenCorner())
    let corner = v.points[1]
    #expect(!corner.hasCurveTo, "the incoming control sat on the anchor and still counted")
    #expect(corner.isCorner, "it should read as a corner")
    #expect(corner.mode == .straight)
}

@Test func realHandlesAreStillKept() {
    // The guard must not throw away curves that are actually curved.
    let v = VectorPath(cgPath: curveThenCorner())
    #expect(v.points[0].hasCurveFrom, "a real outgoing handle was dropped")
    #expect(v.points[0].curveFrom == CGPoint(x: 20, y: 40))
}

@Test func settingAPointStraightSurvivesTheRoundTrip() {
    // The actual complaint: press 1, and the handles come back through the path.
    var v = VectorPath(cgPath: {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addCurve(to: CGPoint(x: 100, y: 0), control1: CGPoint(x: 20, y: 40), control2: CGPoint(x: 80, y: 40))
        p.addCurve(to: CGPoint(x: 200, y: 0), control1: CGPoint(x: 120, y: 40), control2: CGPoint(x: 180, y: 40))
        return p
    }())
    v.points[1].convert(to: .straight, previous: v.points[0].point, next: v.points[2].point)
    let again = VectorPath(cgPath: v.cgPath())
    #expect(again.points.count == 3)
    #expect(again.points[1].isCorner, "the point came back with handles after a round trip")
    #expect(again.points[1].mode == .straight)
}

@Test func aWholePathOfCornersStaysCorners() {
    let rect = CGPath(rect: CGRect(x: 0, y: 0, width: 50, height: 50), transform: nil)
    let v = VectorPath(cgPath: rect)
    let allCorners = v.points.allSatisfy { $0.isCorner }
    #expect(allCorners)
}
