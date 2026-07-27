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

@Test func removingALayerReportsWhereItWasSoUndoCanRestoreIt() {
    var a = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 5, height: 5), transform: nil), closed: true))
    a.id = "a"
    var b = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 5, height: 5), transform: nil), closed: true))
    b.id = "b"
    var group = Layer(kind: .group([a, b])); group.id = "g"
    var page = Page(name: "P")
    page.layers = [group]

    let removed = page.removeLayer("b")
    #expect(removed?.parent == "g")
    #expect(removed?.index == 1)
    #expect(page.layer("b") == nil)

    // Undo puts it back in the same parent at the same index.
    page.insertLayer(removed!.layer, parent: removed!.parent, index: removed!.index)
    guard case .group(let kids) = page.layer("g")!.kind else { Issue.record("expected group"); return }
    #expect(kids.map(\.id) == ["a", "b"])
}

@Test func removingATopLevelLayerHasNoParent() {
    var l = Layer(kind: .group([])); l.id = "top"
    var page = Page(name: "P")
    page.layers = [Layer(kind: .group([])), l]
    let removed = page.removeLayer("top")
    #expect(removed?.parent == nil)
    #expect(removed?.index == 1)
    #expect(page.layers.count == 1)
}

@Test func clipboardRoundTripsLayersAndTheirImages() throws {
    // Pasting into a different document has to bring the pixels along, or the layer
    // arrives pointing at bytes that document has never seen.
    var pic = Layer(kind: .bitmap(imageRef: "images/abc.png"))
    pic.frame = CGRect(x: 10, y: 10, width: 100, height: 80)
    pic.name = "Photo"
    var shape = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 50, height: 50), transform: nil), closed: true))
    shape.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
    shape.style.fills = [Fill(paint: .color(.black))]
    let group = Layer(kind: .group([pic, shape]))

    let bytes = Data("not really a png".utf8)
    let encoded = try AcmplcFile.encodeClipboard(layers: [group], images: ["images/abc.png": bytes])
    let back = try #require(AcmplcFile.decodeClipboard(encoded))

    #expect(back.layers.count == 1)
    #expect(back.images["images/abc.png"] == bytes)
    guard case .group(let kids) = back.layers[0].kind else { Issue.record("expected group"); return }
    #expect(kids.count == 2)
    #expect(kids[0].name == "Photo")
}

@Test func newIDsAreFreshAllTheWayDown() {
    var leaf = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 5, height: 5), transform: nil), closed: true))
    leaf.id = "leaf"
    var inner = Layer(kind: .shapeGroup([leaf], .nonZero)); inner.id = "inner"
    var outer = Layer(kind: .group([inner])); outer.id = "outer"

    let copy = outer.withNewIDs()
    #expect(copy.id != "outer")
    guard case .group(let a) = copy.kind, case .shapeGroup(let b, _) = a[0].kind else {
        Issue.record("structure lost"); return
    }
    #expect(a[0].id != "inner")
    #expect(b[0].id != "leaf")
    #expect(outer.id == "outer")   // the original is untouched
}

@Test func imageRefsGatherFromNestedLayers() {
    let a = Layer(kind: .bitmap(imageRef: "one.png"))
    let b = Layer(kind: .bitmap(imageRef: "two.png"))
    let group = Layer(kind: .group([a, Layer(kind: .group([b]))]))
    #expect(group.imageRefs == ["one.png", "two.png"])
}

@Test func documentDetectionKeepsImagesOutOfTheOpenPath() {
    // The bug this guards: every dropped file went through open(), which cleared the
    // current document before discovering the file wasn't one. A photo wiped your work.
    #expect(DocumentKind.isDocument(URL(fileURLWithPath: "/x/coin.acmplc.png")))
    #expect(DocumentKind.isDocument(URL(fileURLWithPath: "/x/coin.acmplc")))
    #expect(DocumentKind.isDocument(URL(fileURLWithPath: "/x/art.sketch")))
    #expect(!DocumentKind.isDocument(URL(fileURLWithPath: "/x/photo.png")))
    #expect(!DocumentKind.isDocument(URL(fileURLWithPath: "/x/photo.jpg")))
    #expect(!DocumentKind.isDocument(URL(fileURLWithPath: "/x/IMG_1234.HEIC")))
}

@Test func svgReaderHandlesShapesGroupsAndTransforms() throws {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">
      <g transform="translate(10,20)">
        <rect x="0" y="0" width="50" height="40" fill="#ff0000"/>
        <circle cx="100" cy="100" r="25" fill="none" stroke="blue" stroke-width="3"/>
      </g>
      <path d="M0 0 L100 0 L100 100 Z" fill="rgb(0,128,0)"/>
    </svg>
    """
    let r = try SVGReader().read(data: Data(svg.utf8))
    let page = try #require(r.document.pages.first)
    #expect(page.layers.count == 2)          // the <g> plus the loose path

    guard case .group(let kids) = page.layers[0].kind else { Issue.record("expected a group"); return }
    #expect(kids.count == 2)
    // translate(10,20) applied
    #expect(page.layers[0].frame.minX == 10)
    #expect(page.layers[0].frame.minY == 20)
}

@Test func svgTransformsCompose() {
    let t = SVGReader.transform("translate(10,20) scale(2)")
    let p = CGPoint(x: 5, y: 5).applying(t)
    #expect(p.x == 20)   // scaled first, then translated
    #expect(p.y == 30)

    let m = SVGReader.transform("matrix(1,0,0,1,7,8)")
    #expect(CGPoint(x: 0, y: 0).applying(m) == CGPoint(x: 7, y: 8))
}

@Test func svgColoursCoverTheFormsThatActuallyAppear() {
    #expect(SVGReader.color("#ff0000", alpha: 1)?.hex == "#ff0000")
    #expect(SVGReader.color("#f00", alpha: 1)?.hex == "#ff0000")     // shorthand
    #expect(SVGReader.color("rgb(0,128,0)", alpha: 1)?.hex == "#008000")
    #expect(SVGReader.color("blue", alpha: 1)?.hex == "#0000ff")     // named
    #expect(SVGReader.color("none", alpha: 1) == nil)
    #expect(SVGReader.gradientReference("url(#grad1)") == "grad1")
}

@Test func svgTextIsSkippedLoudly() throws {
    // Converting text without its font produces something that looks fine until it's
    // engraved, so it's reported rather than guessed at.
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10"/>
    <text x="0" y="0" font-size="20">Hello</text></svg>
    """
    let r = try SVGReader().read(data: Data(svg.utf8))
    #expect(r.warnings.contains { $0.lowercased().contains("text") })
    #expect(r.document.pages[0].layers.count == 1)   // the rect, not the text
}

private func makePage(_ ids: [String]) -> Page {
    var p = Page(name: "P")
    p.layers = ids.enumerated().map { i, id in
        var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
        l.id = id
        l.frame = CGRect(x: CGFloat(i) * 30, y: CGFloat(i) * 10, width: 10, height: 10)
        return l
    }
    return p
}

@Test func zOrderMovesWithinSiblings() {
    var p = makePage(["a", "b", "c", "d"])   // index 0 is back-most
    p.bringForward(["b"])
    #expect(p.layers.map(\.id) == ["a", "c", "b", "d"])
    p.sendToBack(["b"])
    #expect(p.layers.map(\.id) == ["b", "a", "c", "d"])
    p.bringToFront(["b", "a"])
    #expect(p.layers.map(\.id) == ["c", "d", "b", "a"])
}

@Test func bringForwardStopsAtTheTopRatherThanWrapping() {
    var p = makePage(["a", "b"])
    p.bringForward(["b"])           // already front-most
    #expect(p.layers.map(\.id) == ["a", "b"])
}

@Test func alignUsesTheSelectionBounds() {
    var p = makePage(["a", "b", "c"])
    p.align(["a", "b", "c"], to: .left)
    #expect(p.layers.allSatisfy { $0.frame.minX == 0 })

    var q = makePage(["a", "b", "c"])
    q.align(["a", "b", "c"], to: .verticalMiddle)
    let mid = q.layers.map(\.frame.midY)
    #expect(abs(mid[0] - mid[2]) < 0.001)
}

@Test func distributeEvensTheGapsAndLeavesTheEndsAlone() {
    var p = Page(name: "P")
    p.layers = [(0.0, 10.0), (5.0, 10.0), (100.0, 10.0)].enumerated().map { i, spec in
        var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: spec.1, height: 10), transform: nil), closed: true))
        l.id = "l\(i)"
        l.frame = CGRect(x: spec.0, y: 0, width: spec.1, height: 10)
        return l
    }
    p.distribute(["l0", "l1", "l2"], along: .horizontal)
    let xs = p.layers.map(\.frame.minX).sorted()
    #expect(xs.first == 0)          // ends stay put
    #expect(xs.last == 100)
    #expect(abs((xs[1] - (xs[0] + 10)) - (xs[2] - (xs[1] + 10))) < 0.001)   // equal gaps
}

@Test func groupAndUngroupRoundTripPositions() throws {
    var p = makePage(["a", "b", "c"])
    let before = p.layers.map(\.frame)

    // Called outside #require: the macro can't wrap a mutating member.
    let made = p.group(["a", "b"])
    let gid = try #require(made)
    #expect(p.layers.count == 2)
    guard case .group(let kids) = try #require(p.layer(gid)).kind else {
        Issue.record("expected a group"); return
    }
    #expect(kids.count == 2)
    // Children are stored relative to the group.
    #expect(kids[0].frame.minX == 0)

    let freed = p.ungroup(gid)
    #expect(freed.count == 2)
    #expect(p.layers.count == 3)
    // Ungrouping puts everything back exactly where it was on the canvas.
    #expect(p.layer("a")?.frame == before[0])
    #expect(p.layer("b")?.frame == before[1])
}
