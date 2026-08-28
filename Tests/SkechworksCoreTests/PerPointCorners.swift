import CoreGraphics
import Foundation
import Testing
@testable import SkechworksCore

// A radius per anchor, so a speech balloon's tail can come to a point while its
// box stays round.

/// Adam's bubble: a rectangle with a triangular tail notched out of the bottom.
/// Seven anchors, every corner straight-to-straight, tail tip at index 4.
private func bubble() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: 0))
    p.addLine(to: CGPoint(x: 483, y: 0))
    p.addLine(to: CGPoint(x: 483, y: 206))
    p.addLine(to: CGPoint(x: 252, y: 206))
    p.addLine(to: CGPoint(x: 250, y: 277))     // the tail tip
    p.addLine(to: CGPoint(x: 196, y: 206))
    p.addLine(to: CGPoint(x: 0, y: 206))
    p.closeSubpath()
    return p
}

/// Whether the outline still passes exactly through a corner. A rounded corner
/// is cut away, so the vertex stops being on the path.
private func touches(_ path: CGPath, _ point: CGPoint, slop: CGFloat = 0.6) -> Bool {
    var hit = false
    path.applyWithBlock { e in
        let n = e.pointee.type == .addCurveToPoint ? 3 : (e.pointee.type == .closeSubpath ? 0 : 1)
        for i in 0..<n {
            let q = e.pointee.points[i]
            if hypot(q.x - point.x, q.y - point.y) < slop { hit = true }
        }
    }
    return hit
}

private let tailTip = CGPoint(x: 250, y: 277)
private let topLeft = CGPoint(x: 0, y: 0)

@Test func aLayerRadiusStillRoundsEveryCorner() {
    let rounded = Corners.round(bubble(), radius: 25, style: .rounded)
    #expect(!touches(rounded, tailTip), "the tail tip rounds along with the rest")
    #expect(!touches(rounded, topLeft))
}

@Test func oneAnchorCanStaySharpWhileTheRestRound() {
    // Index 4 is the tail tip. Zero there, 25 everywhere else.
    var radii = [CGFloat](repeating: 25, count: 7)
    radii[4] = 0
    let out = Corners.round(bubble(), radius: 25, style: .rounded, radii: radii)
    #expect(touches(out, tailTip), "a zero radius must leave the tail as a point")
    #expect(!touches(out, topLeft), "and must not stop the other corners rounding")
}

@Test func oneAnchorCanRoundWhileTheLayerRadiusIsZero() {
    var radii = [CGFloat](repeating: 0, count: 7)
    radii[4] = 30
    let out = Corners.round(bubble(), radius: 0, style: .rounded, radii: radii)
    #expect(!touches(out, tailTip), "the tail should be the only rounded corner")
    #expect(touches(out, topLeft), "everything else stays sharp")
}

@Test func anchorsWithNoEntryFallBackToTheLayerRadius() {
    // Documents written before per-point radii carry no array at all.
    let out = Corners.round(bubble(), radius: 25, style: .rounded, radii: [])
    #expect(!touches(out, tailTip))
    // A short array covers what it covers and the rest inherits.
    let partial = Corners.round(bubble(), radius: 25, style: .rounded, radii: [0, 0])
    #expect(!touches(partial, tailTip), "index 4 has no entry, so it takes the layer value")
    #expect(touches(partial, topLeft), "index 0 is explicitly zero")
}

@Test func aNegativeEntryMeansInherit() {
    var radii = [CGFloat](repeating: -1, count: 7)
    radii[4] = 0
    let out = Corners.round(bubble(), radius: 25, style: .rounded, radii: radii)
    #expect(touches(out, tailTip))
    #expect(!touches(out, topLeft), "minus one is not a radius, it is 'use the layer's'")
}

@Test func theRadiiSurviveTheDocumentFormat() throws {
    var l = Layer(kind: .path(bubble(), closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 483, height: 277)
    l.cornerRadius = 25
    l.cornerRadii = [25, 25, 25, 25, 0, 25, 25]
    var page = Page(name: "P")
    page.layers = [l]
    var doc = Document()
    doc.pages = [page]

    let data = try SkechworksFile.write(document: doc, images: [:])
    let back = try SkechworksFile.read(data)
    let reread = try #require(back.document.pages.first?.layers.first)
    #expect(reread.cornerRadii == [25, 25, 25, 25, 0, 25, 25])
    #expect(reread.cornerRadius(at: 4) == 0)
    #expect(reread.cornerRadius(at: 0) == 25)
}

@Test func theInspectorCanTellWhenCornersDisagree() {
    var l = Layer(kind: .path(bubble(), closed: true))
    l.cornerRadius = 25
    #expect(!l.hasMixedCorners, "no array means every corner agrees")
    l.cornerRadii = [CGFloat](repeating: 25, count: 7)
    #expect(!l.hasMixedCorners)
    l.cornerRadii[4] = 0
    #expect(l.hasMixedCorners)
}
