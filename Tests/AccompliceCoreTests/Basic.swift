import CoreGraphics
import Foundation
import Testing

@testable import AccompliceCore

// The polyglot is the load-bearing claim of this whole format, so it gets tested
// from both directions on every build.

@Test func zipRoundTrips() throws {
    let entries = [
        ZipEntry(name: "document.json", data: Data(#"{"format":"acmplc"}"#.utf8)),
        ZipEntry(name: "exports/page.svg", data: Data(String(repeating: "<path/>", count: 500).utf8)),
    ]
    let back = try Zip.read(Zip.write(entries))
    #expect(back.count == 2)
    #expect(String(decoding: back["document.json"]!, as: UTF8.self) == #"{"format":"acmplc"}"#)
    #expect(back["exports/page.svg"]!.count == 3500)   // survived the deflate round-trip
}

@Test func pngZipPolyglotIsBothThings() throws {
    var doc = Document()
    var page = Page(name: "One Year")
    var l = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil),
                              closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    l.style.fills = [Fill(paint: .color(.black))]
    page.layers = [l]
    doc.pages = [page]

    let data = try AcmplcFile.write(document: doc, images: [:])

    // 1. Still a PNG.
    #expect(data.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

    // 2. Still a ZIP, and the artwork is really in there.
    let back = try Zip.read(data)
    #expect(back["document.json"] != nil)
    #expect(back["README.txt"] != nil)
    let svg = back.first { $0.key.hasPrefix("exports/") && $0.key.hasSuffix(".svg") }
    let text = try #require(svg.map { String(decoding: $0.value, as: UTF8.self) })
    #expect(text.contains("<svg"))
    #expect(text.contains("<path"))
}

@Test func booleanSubtractRemovesArea() throws {
    // A ring: outer circle minus inner. Guards the CGPath boolean composition that
    // all of the coin artwork depends on.
    var outer = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil), closed: true))
    outer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    var inner = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 50, height: 50), transform: nil), closed: true))
    inner.frame = CGRect(x: 25, y: 25, width: 50, height: 50)
    inner.booleanOp = .subtract

    let group = Layer(kind: .shapeGroup([outer, inner], .nonZero))
    let p = try #require(Compose.resolvedPath(group))
    #expect(p.contains(CGPoint(x: 50, y: 5)))       // on the ring
    #expect(!p.contains(CGPoint(x: 50, y: 50)))     // hole in the middle
}

@Test func svgPathDataSurvivesRoundTrip() {
    // Geometry is stored as SVG path syntax, so the parser is part of the format's
    // durability guarantee, not a convenience.
    let original = CGMutablePath()
    original.move(to: CGPoint(x: 10, y: 20))
    original.addCurve(to: CGPoint(x: 100, y: 200), control1: CGPoint(x: 30, y: 40), control2: CGPoint(x: 70, y: 90))
    original.addQuadCurve(to: CGPoint(x: 5, y: 5), control: CGPoint(x: 0, y: 100))
    original.addLine(to: CGPoint(x: 10, y: 20))
    original.closeSubpath()

    let d = SVGWriter().pathData(original)
    let back = PathParser.path(from: d)
    #expect(SVGWriter().pathData(back) == d)
    #expect(back.boundingBox.equalTo(original.boundingBox))
}

@Test func pathParserHandlesRelativeAndShorthand() {
    // Not emitted by us, but valid SVG a human (or another tool) might hand us.
    let p = PathParser.path(from: "m 10 10 h 20 v 20 h -20 z")
    #expect(p.boundingBox.equalTo(CGRect(x: 10, y: 10, width: 20, height: 20)))
}

@Test func textAlignmentSurvivesTheDocumentFormat() throws {
    // Regression: alignment was missing from the serializer, so every centred block
    // came back left-aligned — silently wrong on reopen.
    var run = TextRun()
    run.string = "ONE\nYEAR\nSOBER"
    run.alignment = .center
    run.fontSize = 44
    var l = Layer(kind: .text(run))
    l.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
    var page = Page(name: "Front")
    page.layers = [l]
    var doc = Document()
    doc.pages = [page]

    let (back, _) = try AcmplcFile.read(try AcmplcFile.write(document: doc, images: [:]))
    guard case .text(let r) = try #require(back.pages.first?.layers.first).kind else {
        Issue.record("expected a text layer"); return
    }
    #expect(r.alignment == .center)
    #expect(r.string == "ONE\nYEAR\nSOBER")
    #expect(r.fontSize == 44)
}

@Test func strippedPayloadIsReportedNotGuessed() {
    // A plain PNG with no appended archive is the optimizer-stripped case. It must
    // fail loudly rather than silently open as an empty document.
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: 256)
    #expect(throws: (any Error).self) { try AcmplcFile.read(png) }
}

@Test func groupInsideShapeGroupStillComposes() {
    // Regression: plain groups nested inside a shapeGroup were being dropped, which
    // silently deleted the dot clusters from the moon-phases coin.
    var dot = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 20, height: 20), transform: nil), closed: true))
    dot.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
    var wrapper = Layer(kind: .group([dot]))
    wrapper.frame = CGRect(x: 40, y: 40, width: 20, height: 20)
    #expect(Compose.resolvedPath(wrapper) != nil)
}

@Test func updateLayerReachesNestedLayers() {
    var inner = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    inner.id = "target"
    inner.frame = CGRect(x: 5, y: 5, width: 10, height: 10)
    let mid = Layer(kind: .shapeGroup([inner], .nonZero))
    var outer = Layer(kind: .group([mid]))
    outer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

    var page = Page(name: "P")
    page.layers = [outer]

    #expect(page.updateLayer("target") { $0.frame.origin.x = 42 })
    #expect(page.layer("target")?.frame.minX == 42)
    #expect(!page.updateLayer("nope") { _ in })   // reports misses rather than silently no-op'ing
}

@Test func editsSurviveSaveAndReload() throws {
    // The whole point of the edit path: a change has to still be there after the
    // document round-trips through .acmplc.png.
    var l = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 50, height: 50), transform: nil), closed: true))
    l.id = "moveme"
    l.frame = CGRect(x: 10, y: 10, width: 50, height: 50)
    l.style.fills = [Fill(paint: .color(.black))]
    var page = Page(name: "One")
    page.layers = [l]
    var doc = Document()
    doc.pages = [page]

    doc.pages[0].updateLayer("moveme") {
        $0.frame.origin = CGPoint(x: 123, y: 456)
        $0.style.opacity = 0.5
        $0.isVisible = false
    }

    let (back, _) = try AcmplcFile.read(try AcmplcFile.write(document: doc, images: [:]))
    let reloaded = try #require(back.pages.first?.layer("moveme"))
    #expect(reloaded.frame.minX == 123)
    #expect(reloaded.frame.minY == 456)
    #expect(reloaded.style.opacity == 0.5)
    #expect(reloaded.isVisible == false)
}

@Test func resizeScalesGeometryNotJustTheFrame() throws {
    // Stretching a frame must take the art with it. Paths live in absolute local
    // units, so a naive frame change would leave the geometry behind.
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 50), transform: nil), closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 50)

    l.resize(to: CGSize(width: 200, height: 50))
    #expect(l.frame.width == 200)
    let p = try #require(Compose.resolvedPath(l))
    #expect(p.boundingBox.width == 200)      // geometry followed the frame
    #expect(p.boundingBox.height == 50)      // untouched axis stayed put
}

@Test func resizeRecursesThroughGroups() throws {
    var dot = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    dot.frame = CGRect(x: 40, y: 40, width: 10, height: 10)
    var group = Layer(kind: .group([dot]))
    group.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

    group.resize(to: CGSize(width: 50, height: 100))   // half as wide

    guard case .group(let kids) = group.kind else { Issue.record("expected group"); return }
    #expect(kids[0].frame.minX == 20)     // origin scaled
    #expect(kids[0].frame.width == 5)     // size scaled
    let p = try #require(Compose.resolvedPath(kids[0]))
    #expect(p.boundingBox.width == 5)     // and the child's own geometry too
}

@Test func uniformResizeScalesTypeButUnevenDoesNot() {
    var run = TextRun()
    run.fontSize = 20
    var l = Layer(kind: .text(run))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

    var uniform = l
    uniform.resize(to: CGSize(width: 200, height: 200))
    guard case .text(let a) = uniform.kind else { Issue.record("expected text"); return }
    #expect(a.fontSize == 40)

    var uneven = l
    uneven.resize(to: CGSize(width: 200, height: 100))
    guard case .text(let b) = uneven.kind else { Issue.record("expected text"); return }
    #expect(b.fontSize == 20)             // box re-wraps; glyphs are never distorted
    #expect(uneven.frame.width == 200)
}

@Test func vectorPathRoundTripsThroughCGPath() {
    // The pen tool edits points; the model stores a baked CGPath. That conversion has
    // to be lossless or every edit would drift the geometry.
    let m = CGMutablePath()
    m.move(to: CGPoint(x: 0, y: 0))
    m.addCurve(to: CGPoint(x: 100, y: 0), control1: CGPoint(x: 20, y: -40), control2: CGPoint(x: 80, y: -40))
    m.addLine(to: CGPoint(x: 100, y: 100))
    m.addCurve(to: CGPoint(x: 0, y: 100), control1: CGPoint(x: 80, y: 140), control2: CGPoint(x: 20, y: 140))
    m.closeSubpath()

    let vp = VectorPath(cgPath: m.copy()!)
    #expect(vp.closed)
    #expect(vp.points.count == 4)
    #expect(SVGWriter().pathData(vp.cgPath()) == SVGWriter().pathData(m.copy()!))
}

@Test func bendMovesTheCurveMidpointToTheCursor() {
    // The headline interaction: drag the curve itself and it follows.
    var vp = VectorPath(points: [VectorPoint(CGPoint(x: 0, y: 0)),
                                 VectorPoint(CGPoint(x: 100, y: 0))])
    let target = CGPoint(x: 50, y: 60)
    vp.bend(segment: 0, to: target)

    let mid = VectorPath.evaluate(vp.points[0], vp.points[1], 0.5)
    #expect(abs(mid.x - target.x) < 0.01)
    #expect(abs(mid.y - target.y) < 0.01)
    #expect(vp.points[0].point == CGPoint(x: 0, y: 0))   // anchors don't move
    #expect(vp.points[1].point == CGPoint(x: 100, y: 0))
}

@Test func deletingAPointKeepsTheCurveRatherThanFlattening() {
    var vp = VectorPath(points: [VectorPoint(CGPoint(x: 0, y: 0)),
                                 VectorPoint(CGPoint(x: 50, y: 0)),
                                 VectorPoint(CGPoint(x: 100, y: 0))])
    vp.bend(segment: 0, to: CGPoint(x: 25, y: 40))
    vp.bend(segment: 1, to: CGPoint(x: 75, y: 40))
    vp.removePoint(1)
    #expect(vp.points.count == 2)
    #expect(vp.points[0].hasCurveFrom)   // inherited the departed point's handles
    #expect(vp.points[1].hasCurveTo)
}

@Test func handleModesPullTheOppositeHandle() {
    var p = VectorPoint(CGPoint(x: 100, y: 100))
    p.mode = .mirrored
    p.setHandle(out: true, to: CGPoint(x: 150, y: 100))
    #expect(abs(p.curveTo.x - 50) < 0.01)     // mirrored to the far side
    #expect(abs(p.curveTo.y - 100) < 0.01)

    var d = VectorPoint(CGPoint(x: 100, y: 100))
    d.mode = .disconnected
    d.curveTo = CGPoint(x: 90, y: 90); d.hasCurveTo = true
    d.setHandle(out: true, to: CGPoint(x: 150, y: 100))
    #expect(d.curveTo == CGPoint(x: 90, y: 90))   // independent, untouched
}

@Test func ancestorsLeadFromTheOutsideIn() {
    // Drives "select on canvas, reveal in the layer list" — the trail has to be
    // outermost-first so each group can be opened on the way down.
    var leaf = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 5, height: 5), transform: nil), closed: true))
    leaf.id = "leaf"
    var inner = Layer(kind: .shapeGroup([leaf], .nonZero)); inner.id = "inner"
    var outer = Layer(kind: .group([inner])); outer.id = "outer"
    var page = Page(name: "P")
    page.layers = [outer]

    #expect(page.ancestors(of: "leaf") == ["outer", "inner"])
    #expect(page.ancestors(of: "outer") == [])
    #expect(page.ancestors(of: "missing") == [])
}
