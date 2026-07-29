import CoreGraphics
import Foundation
import Testing

@testable import AccompliceCore

// Corner rounding is geometry nobody eyeballs correctly: a sweep going the wrong way
// round, or a fillet eating more edge than there is, both still draw *something*.

private var square: CGPath { CGPath(rect: CGRect(x: 0, y: 0, width: 200, height: 200), transform: nil) }

/// Points the curve actually passes through — not control points, which sit off it.
private func endpoints(of path: CGPath) -> [CGPoint] {
    var out: [CGPoint] = []
    path.applyWithBlock { e in
        switch e.pointee.type {
        case .moveToPoint, .addLineToPoint: out.append(e.pointee.points[0])
        case .addQuadCurveToPoint: out.append(e.pointee.points[1])
        case .addCurveToPoint: out.append(e.pointee.points[2])
        default: break
        }
    }
    return out
}

/// How far from the corner the outline leaves the top edge.
private func departure(_ path: CGPath) -> CGFloat {
    endpoints(of: path).filter { abs($0.y) < 0.001 }.map(\.x).min() ?? .infinity
}

@Test func roundingKeepsTheShapeInsideItsOwnBox() {
    for style in CornerStyle.allCases {
        let r = Corners.round(square, radius: 40, style: style).boundingBoxOfPath
        // Tangent to both edges means the box is untouched — a fillet that bulged past
        // the original would show up here, and so would an arc swept the wrong way.
        #expect(abs(r.minX) < 0.01 && abs(r.minY) < 0.01)
        #expect(abs(r.maxX - 200) < 0.01 && abs(r.maxY - 200) < 0.01)
    }
}

@Test func theCornerItselfIsGone() {
    for style in CornerStyle.allCases {
        let rounded = Corners.round(square, radius: 40, style: style)
        #expect(!endpoints(of: rounded).contains { hypot($0.x, $0.y) < 1 })
        // …but the middle of an edge is untouched.
        #expect(rounded.contains(CGPoint(x: 100, y: 1)))
        #expect(!rounded.contains(CGPoint(x: 1, y: 1)))
    }
}

@Test func smoothLeavesTheStraightEarlierThanAnArcDoes() {
    // The whole difference between the two: an arc switches from straight to curved at
    // one point, and a squircle spends `1 + smoothing` times as much edge easing into it.
    #expect(abs(departure(Corners.round(square, radius: 40, style: .rounded)) - 40) < 0.01)
    let smooth = departure(Corners.round(square, radius: 40, style: .smooth))
    #expect(abs(smooth - 40 * (1 + Corners.smoothing)) < 0.01)
}

@Test func anImpossibleRadiusClampsInsteadOfExploding() {
    for style in CornerStyle.allCases {
        let huge = Corners.round(square, radius: 5000, style: style)
        let box = huge.boundingBoxOfPath
        #expect(abs(box.minX) < 0.01 && abs(box.width - 200) < 0.01)
        #expect(endpoints(of: huge).allSatisfy { $0.x.isFinite && $0.y.isFinite })
        // Fully round-over: nothing of the straight edge is left between two corners
        // that have each taken half of it.
        #expect(departure(huge) > 99)
    }
}

@Test func aRadiusOfZeroChangesNothing() {
    #expect(Corners.round(square, radius: 0, style: .smooth) == square)
}

@Test func onlyStraightToStraightCornersCount() {
    #expect(Corners.roundableCorners(in: square) == 4)
    // A circle has no corners, which is why the inspector doesn't offer the control.
    let circle = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)
    #expect(Corners.roundableCorners(in: circle) == 0)
    #expect(Corners.round(circle, radius: 20, style: .smooth) == circle)
}

@Test func aCornerBetweenCurvesIsLeftAlone() {
    // Two straight edges meeting at (100, 0), then a curve back round. Only the one
    // corner with a straight on both sides should change.
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: 100))
    p.addLine(to: CGPoint(x: 100, y: 0))
    p.addLine(to: CGPoint(x: 200, y: 100))
    p.addCurve(to: CGPoint(x: 0, y: 100), control1: CGPoint(x: 200, y: 220),
               control2: CGPoint(x: 0, y: 220))
    p.closeSubpath()
    let shape = p.copy()!
    #expect(Corners.roundableCorners(in: shape) == 1)
    let rounded = Corners.round(shape, radius: 20, style: .rounded)
    #expect(!endpoints(of: rounded).contains { hypot($0.x - 100, $0.y) < 1 })
    // The two curve ends are still exactly where they were.
    #expect(endpoints(of: rounded).contains { hypot($0.x - 200, $0.y - 100) < 0.01 })
    #expect(endpoints(of: rounded).contains { hypot($0.x, $0.y - 100) < 0.01 })
}

@Test func composeIsWhereTheRadiusBecomesGeometry() {
    var l = Layer(kind: .path(square, closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    #expect(Compose.resolvedPath(l) == square)   // stored sharp, always

    l.cornerRadius = 30
    l.cornerStyle = .smooth
    let out = Compose.resolvedPath(l)
    #expect(out != square)
    #expect(abs(departure(out!) - 30 * (1 + Corners.smoothing)) < 0.01)

    // And the layer itself still holds the sharp outline, so the number stays a number.
    guard case .path(let stored, _) = l.kind else { Issue.record("kind changed"); return }
    #expect(stored == square)
}

@Test func cornersSurviveTheFileFormat() throws {
    var doc = Document()
    var page = Page(name: "Corners")
    var l = Layer(kind: .path(square, closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    l.cornerRadius = 18
    l.cornerStyle = .smooth
    page.layers = [l]
    doc.pages = [page]

    let (back, _) = try AcmplcFile.read(try AcmplcFile.write(document: doc, images: [:]))
    let read = back.pages[0].layers[0]
    #expect(read.cornerRadius == 18)
    #expect(read.cornerStyle == .smooth)
}
