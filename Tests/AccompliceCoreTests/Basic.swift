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

private func styledPage() -> Page {
    var p = Page(name: "Coins")
    func shape(_ id: String, _ name: String, fill: Color?, w: CGFloat = 100) -> Layer {
        var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: w, height: 50), transform: nil), closed: true))
        l.id = id; l.name = name
        l.frame = CGRect(x: 0, y: 0, width: w, height: 50)
        if let f = fill { l.style.fills = [Fill(paint: .color(f))] }
        return l
    }
    var text = Layer(kind: .text({ var t = TextRun(); t.string = "ONE YEAR SOBER"; return t }()))
    text.id = "t1"; text.name = "Ring"
    text.frame = CGRect(x: 0, y: 0, width: 200, height: 40)

    var board = Layer(kind: .group([shape("s3", "Inner", fill: .black)]))
    board.id = "ab"; board.name = "front"; board.isArtboard = true
    board.frame = CGRect(x: 0, y: 0, width: 500, height: 500)

    p.layers = [shape("s1", "Circle", fill: .black),
                shape("s2", "Halo", fill: Color(r: 1, g: 1, b: 1, a: 1), w: 300),
                text, board]
    return p
}

@Test func queriesFindLayersByTheThingsAModelWouldSay() {
    let p = styledPage()
    #expect(Set(p.find({ var q = LayerQuery(); q.fill = "#000000"; return q }())) == ["s1", "s3"])
    #expect(p.find({ var q = LayerQuery(); q.type = "text"; return q }()) == ["t1"])
    #expect(p.find({ var q = LayerQuery(); q.type = "artboard"; return q }()) == ["ab"])
    #expect(p.find({ var q = LayerQuery(); q.text = "sober"; return q }()) == ["t1"])   // case-insensitive
    #expect(p.find({ var q = LayerQuery(); q.name = "hal"; return q }()) == ["s2"])
    #expect(p.find({ var q = LayerQuery(); q.minWidth = 250; return q }()).contains("s2"))
}

@Test func queryLimitCapsTheBlastRadius() {
    let p = styledPage()
    var q = LayerQuery(); q.limit = 1
    #expect(p.find(q).count == 1)
}

@Test func commandsDecodeFromTheJSONAModelWouldWrite() {
    let json = """
    {"commands":[
      {"op":"setOpacity","type":"path","fill":"#000000","value":50},
      {"op":"rename","where":{"type":"text"},"pattern":"label-{i}"},
      {"op":"hide","name":"Halo"}
    ]}
    """
    let cmds = DocumentCommand.decodeList(Data(json.utf8))
    #expect(cmds.count == 3)

    guard case .setOpacity(let q, let v) = cmds[0] else { Issue.record("expected setOpacity"); return }
    #expect(q.fill == "#000000")
    #expect(v == 0.5)                       // 50 accepted as a percentage

    guard case .rename(let q2, let pattern) = cmds[1] else { Issue.record("expected rename"); return }
    #expect(q2.type == "text")              // nested "where" understood too
    #expect(pattern == "label-{i}")

    guard case .setVisible(_, let visible) = cmds[2] else { Issue.record("expected setVisible"); return }
    #expect(visible == false)               // bare "hide" implies false
}

@Test func describeStaysSmallEnoughForAContextWindow() {
    let p = styledPage()
    let text = p.describe()
    #expect(text.contains("artboard “front”"))
    #expect(text.contains("fill #000000"))
    #expect(text.contains("ONE YEAR SOBER"))
    // Geometry is summarised, never dumped — a coin page is ~900k curve points, and
    // a context window is not the place for them. Look for path-data syntax
    // specifically rather than a bare letter, which "Coins" happens to contain.
    let looksLikePathData = text.range(of: "[MLCQZ] *-?[0-9]", options: .regularExpression)
    #expect(looksLikePathData == nil)
    #expect(text.count < 2000)
}

@Test func anUnscopedCommandIsNotAWildcard() {
    // A real local model, asked to "remove all the layers with black fill", replied:
    //   [{"op":"select","type":"path","fill":"#000000"},{"op":"delete"}]
    // The delete carries no selector. Treated as "match everything" that wipes the
    // document, so an empty query has to be recognisable as empty.
    let cmds = DocumentCommand.decodeList(Data("""
    {"commands":[{"op":"select","type":"path","fill":"#000000"},{"op":"delete"}]}
    """.utf8))
    #expect(cmds.count == 2)
    #expect(cmds[0].query.isEmpty == false)
    #expect(cmds[1].query.isEmpty == true)
}

@Test func contentSignatureNoticesChangesThatDontMoveAnything() {
    // The bug this guards: the no-op check compared only ids and frames, so a rename
    // looked identical to no change and was silently discarded. An MCP rename
    // reported "4 layers" and did nothing.
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    l.id = "x"; l.name = "before"
    l.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    var page = Page(name: "P"); page.layers = [l]
    let original = page.contentSignature

    var renamed = page
    renamed.updateLayer("x") { $0.name = "after" }
    #expect(renamed.contentSignature != original)

    var recoloured = page
    recoloured.updateLayer("x") { $0.style.fills = [Fill(paint: .color(.black))] }
    #expect(recoloured.contentSignature != original)

    var faded = page
    faded.updateLayer("x") { $0.style.opacity = 0.5 }
    #expect(faded.contentSignature != original)

    var hidden = page
    hidden.updateLayer("x") { $0.isVisible = false }
    #expect(hidden.contentSignature != original)

    var untouched = page
    untouched.updateLayer("x") { _ in }
    #expect(untouched.contentSignature == original)
}

@Test func setFillAcceptsTheKeyTheModelActuallyUsed() {
    // Verbatim from qwen3-coder:30b, asked to "update all the black fills to dark
    // gray". It used "value" where the schema said "hex"; the strict decoder dropped
    // the command and the model's "Changed all black fills" stood with nothing behind it.
    let reply = """
    {"say":"Changed all black fills to dark gray.",
     "commands":[{"op":"setFill","fill":"#000000","value":"#333333"}]}
    """
    let turn = ModelTurn.decode(Data(reply.utf8))
    #expect(turn.commands.count == 1)
    #expect(turn.problems.isEmpty)
    guard case .setFill(let q, let hex) = turn.commands[0] else {
        Issue.record("expected setFill"); return
    }
    #expect(q.fill == "#000000")     // selector: which layers
    #expect(hex == "#333333")        // parameter: the new colour
}

@Test func anUnreadableCommandIsReportedNotDropped() {
    // ##"..."## because the JSON contains `"#`, which closes a #"..."# literal early.
    let reply = ##"{"say":"Done!","commands":[{"op":"setFill","fill":"#000000"}]}"##
    let turn = ModelTurn.decode(Data(reply.utf8))
    #expect(turn.commands.isEmpty)
    #expect(turn.problems.count == 1)          // the claim can't stand unchallenged
    #expect(turn.problems[0].contains("setFill"))
}

// MARK: - Curved text

private func arcRun(_ s: String, radius: CGFloat, angle: CGFloat, flipped: Bool = false) -> TextRun {
    var run = TextRun()
    run.string = s
    run.fontName = "Helvetica"
    run.fontSize = 24
    run.arc = TextArc(radius: radius, angle: angle, flipped: flipped)
    return run
}

private let arcFrame = CGRect(x: 0, y: 0, width: 400, height: 400)   // centre (200, 200)

@Test func curvedTextSitsOnTheCircleAtTwelveOClock() throws {
    let p = try #require(TextOutline.path(arcRun("A", radius: 100, angle: 0), in: arcFrame))
    let b = p.boundingBoxOfPath
    // Centred on the angle, so horizontally centred on the frame.
    #expect(abs(b.midX - 200) < 2)
    // Baseline on the circle: y = 200 - 100. Glyph rises outward (smaller y).
    #expect(abs(b.maxY - 100) < 2)
    #expect(b.minY < 100)
}

@Test func curvedTextFollowsTheAngleRoundTheCircle() throws {
    // 3 o'clock: on the +x side, and the glyph leans outward past the radius.
    let p = try #require(TextOutline.path(arcRun("A", radius: 100, angle: 90), in: arcFrame))
    let b = p.boundingBoxOfPath
    #expect(abs(b.midY - 200) < 2)
    #expect(b.minX > 295)          // baseline at x = 300
    #expect(b.maxX > 300)          // rises outward
}

@Test func flippedCurvedTextReadsUprightAlongTheBottom() throws {
    let p = try #require(TextOutline.path(arcRun("A", radius: 100, angle: 180, flipped: true),
                                          in: arcFrame))
    let b = p.boundingBoxOfPath
    #expect(abs(b.midX - 200) < 2)
    // Baseline on the circle at y = 300, glyph upright so it rises toward the centre.
    #expect(abs(b.maxY - 300) < 2)
    #expect(b.minY < 300)
}

@Test func longCurvedTextWrapsRoundRatherThanRunningStraight() throws {
    // A string long enough to pass a quarter turn must curve: a straight line of the
    // same text would be far wider than it is tall.
    let p = try #require(TextOutline.path(arcRun("25,600 MINUTES OF THIS", radius: 80, angle: 0),
                                          in: arcFrame))
    let b = p.boundingBoxOfPath
    #expect(b.height > 60)         // straight text would be ~24 tall
    #expect(b.width < 260)         // and ~280 wide
}

@Test func arcSurvivesSaveAndReload() throws {
    var doc = Document()
    var page = Page(name: "Page 1")
    var layer = Layer(kind: .text(arcRun("8760 HOURS", radius: 120, angle: 45, flipped: true)))
    layer.name = "ring"
    layer.frame = arcFrame
    page.layers = [layer]
    doc.pages = [page]

    let data = try AcmplcFile.write(document: doc, images: [:])
    let (back, _) = try AcmplcFile.read(data)
    guard case .text(let run) = back.pages[0].layers[0].kind, let a = run.arc else {
        Issue.record("arc lost on reload"); return
    }
    #expect(a.radius == 120)
    #expect(a.angle == 45)
    #expect(a.flipped)
}

@Test func curveCommandBendsAndStraightensText() {
    var page = Page(name: "p")
    var l = Layer(kind: .text(arcRun("8760 HOURS", radius: 0, angle: 0)))
    if case .text(var r) = l.kind { r.arc = nil; l.kind = .text(r) }   // start straight
    l.frame = arcFrame
    l.name = "hours"
    page.layers = [l]

    func arc(_ p: Page) -> TextArc? {
        guard case .text(let r) = p.layers[0].kind else { return nil }
        return r.arc
    }

    let bend = DocumentCommand.decodeList(Data(#"""
    [{"op":"curve","name":"hours","radius":120,"angle":180,"flipped":true}]
    """#.utf8))
    #expect(bend.count == 1)
    _ = page.run(bend)
    #expect(arc(page)?.radius == 120)
    #expect(arc(page)?.angle == 180)
    #expect(arc(page)?.flipped == true)

    // Angle alone must not discard the radius already set.
    _ = page.run(DocumentCommand.decodeList(Data(#"[{"op":"curve","name":"hours","angle":90}]"#.utf8)))
    #expect(arc(page)?.radius == 120)
    #expect(arc(page)?.angle == 90)

    _ = page.run(DocumentCommand.decodeList(Data(#"[{"op":"curve","name":"hours","straighten":true}]"#.utf8)))
    #expect(arc(page) == nil)
}

// MARK: - Creating layers

@Test func chatCanCreateAnArtboard() {
    var page = Page(name: "p")
    // "make a new artboard" — the request that had nothing behind it.
    let cmds = DocumentCommand.decodeList(Data(#"[{"op":"add","kind":"artboard"}]"#.utf8))
    #expect(cmds.count == 1)
    let run = page.run(cmds)
    #expect(page.layers.count == 1)
    #expect(page.layers[0].isArtboard)
    #expect(page.layers[0].frame.size == CGSize(width: 500, height: 500))
    #expect(run.selection?.count == 1)          // and it ends up selected
}

@Test func addAcceptsTheOpNameAloneWithoutAKind() {
    // Models reach for op:"addArtboard" as readily as op:"add",kind:"artboard".
    let cmds = DocumentCommand.decodeList(Data(#"[{"op":"addArtboard","name":"Front"}]"#.utf8))
    var page = Page(name: "p")
    _ = page.run(cmds)
    #expect(page.layers.count == 1)
    #expect(page.layers[0].isArtboard)
    #expect(page.layers[0].name == "Front")
}

@Test func addPlacesAShapeInsideANamedArtboard() {
    var page = Page(name: "p")
    _ = page.run(DocumentCommand.decodeList(Data(#"[{"op":"add","kind":"artboard","name":"Front"}]"#.utf8)))
    _ = page.run(DocumentCommand.decodeList(Data("""
    [{"op":"add","kind":"ellipse","name":"Disc","parent":"Front","fill":"#ff0000"}]
    """.utf8)))

    #expect(page.layers.count == 1)                  // nested, not a sibling
    guard case .group(let kids) = page.layers[0].kind else { Issue.record("no kids"); return }
    #expect(kids.count == 1)
    #expect(kids[0].name == "Disc")
    // Positioned relative to the artboard, so it lands inside it rather than off-page.
    #expect(kids[0].frame.minX >= 0)
    #expect(kids[0].frame.maxX <= 500)
}

@Test func addCreatesCurvableText() {
    var page = Page(name: "p")
    _ = page.run(DocumentCommand.decodeList(Data("""
    [{"op":"add","kind":"text","text":"8760 HOURS","fontSize":30,"name":"hours"},
     {"op":"curve","name":"hours","radius":200,"flipped":true}]
    """.utf8)))
    guard case .text(let run) = page.layers[0].kind else { Issue.record("not text"); return }
    #expect(run.string == "8760 HOURS")
    #expect(run.arc?.radius == 200)
    #expect(run.arc?.flipped == true)
}

@Test func duplicateMakesTheAskedForNumberOfCopies() {
    var page = Page(name: "p")
    _ = page.run(DocumentCommand.decodeList(Data(#"[{"op":"add","kind":"rect","name":"box"}]"#.utf8)))
    _ = page.run(DocumentCommand.decodeList(Data(#"[{"op":"duplicate","name":"box","times":3,"dx":50,"dy":0}]"#.utf8)))
    #expect(page.layers.count == 4)
    // Distinct ids, or selection and editing would act on all of them at once.
    #expect(Set(page.layers.map(\.id)).count == 4)
    let xs = page.layers.map(\.frame.minX).sorted()
    #expect(xs[1] - xs[0] == 50)
}

@Test func addPrefersAnExactlyNamedParentOverALooseMatch() {
    // A real run: the Texas file already had "back", the model created "Back", and
    // the circle went silently into the old coin instead of the new artboard.
    var page = Page(name: "p")
    var old = Layer(kind: .group([]))
    old.name = "back"
    old.isArtboard = true
    old.frame = CGRect(x: 0, y: 0, width: 2000, height: 2000)
    page.layers = [old]

    _ = page.run(DocumentCommand.decodeList(Data("""
    [{"op":"add","kind":"artboard","name":"Back","width":400,"height":400},
     {"op":"add","kind":"ellipse","name":"Disc","parent":"Back"}]
    """.utf8)))

    guard case .group(let oldKids) = page.layers[0].kind,
          case .group(let newKids) = page.layers[1].kind else {
        Issue.record("expected two artboards"); return
    }
    #expect(page.layers[1].name == "Back")
    #expect(newKids.count == 1)            // the disc landed in the new artboard
    #expect(newKids[0].name == "Disc")
    #expect(oldKids.isEmpty)               // and not in the old one
}

@Test func addFallsBackToACaseInsensitiveParent() {
    var page = Page(name: "p")
    _ = page.run(DocumentCommand.decodeList(Data(#"[{"op":"add","kind":"artboard","name":"Front"}]"#.utf8)))
    _ = page.run(DocumentCommand.decodeList(Data(#"[{"op":"add","kind":"rect","name":"Box","parent":"front"}]"#.utf8)))
    guard case .group(let kids) = page.layers[0].kind else { Issue.record("no group"); return }
    #expect(kids.count == 1)
}

@Test func coordinatesInsideAnArtboardAreRelativeToIt() {
    // The artboard sits far from the origin, as it does in a real multi-coin page.
    var page = Page(name: "p")
    _ = page.run(DocumentCommand.decodeList(Data("""
    [{"op":"add","kind":"artboard","name":"Back","x":2000,"y":1400,"width":400,"height":400},
     {"op":"add","kind":"ellipse","name":"Disc","parent":"Back","x":100,"y":100,"width":200,"height":200}]
    """.utf8)))
    guard case .group(let kids) = page.layers[0].kind else { Issue.record("no kids"); return }
    // 100 from the artboard's corner, not 100 minus the artboard's origin.
    #expect(kids[0].frame.origin == CGPoint(x: 100, y: 100))
    #expect(kids[0].frame.maxX <= 400)      // stays inside
}

@Test func anUnpositionedChildIsCentredInItsArtboard() {
    var page = Page(name: "p")
    _ = page.run(DocumentCommand.decodeList(Data("""
    [{"op":"add","kind":"artboard","name":"Back","x":900,"y":900,"width":400,"height":400},
     {"op":"add","kind":"ellipse","parent":"Back","width":200,"height":200}]
    """.utf8)))
    guard case .group(let kids) = page.layers[0].kind else { Issue.record("no kids"); return }
    #expect(kids[0].frame.origin == CGPoint(x: 100, y: 100))
}

@Test func curvingTextGrowsTheFrameToHoldTheRing() {
    var page = Page(name: "p")
    _ = page.run(DocumentCommand.decodeList(Data("""
    [{"op":"add","kind":"text","text":"8760 HOURS","fontSize":30,"width":400,"height":70},
     {"op":"curve","radius":200,"angle":180,"flipped":true}]
    """.utf8)))
    let l = page.layers[0]
    // A radius-200 ring needs ~400+ across; a 400x70 box would clip it away entirely.
    #expect(l.frame.width >= 400)
    #expect(l.frame.height >= 400)

    // Every glyph has to land inside the layer, or an artboard will clip it off.
    guard case .text(let run) = l.kind else { Issue.record("not text"); return }
    let box = TextOutline.path(run, in: CGRect(origin: .zero, size: l.frame.size))!.boundingBoxOfPath
    #expect(box.minX >= 0)
    #expect(box.minY >= 0)
    #expect(box.maxX <= l.frame.width)
    #expect(box.maxY <= l.frame.height)
}

@Test func curvingTextKeepsItWhereItWas() {
    var page = Page(name: "p")
    _ = page.run(DocumentCommand.decodeList(Data("""
    [{"op":"add","kind":"text","text":"HOURS","x":300,"y":300,"width":400,"height":70},
     {"op":"curve","radius":150}]
    """.utf8)))
    // Centre stays put: curving must not also move the text.
    #expect(abs(page.layers[0].frame.midX - 500) < 0.01)
    #expect(abs(page.layers[0].frame.midY - 335) < 0.01)
}

@Test func aRingInsideAnArtboardIsConcentricWithIt() {
    var page = Page(name: "p")
    _ = page.run(DocumentCommand.decodeList(Data("""
    [{"op":"add","kind":"artboard","name":"Back","width":400,"height":400},
     {"op":"add","kind":"text","text":"8760 HOURS","fontSize":24,"parent":"Back","x":50,"y":320},
     {"op":"curve","radius":150,"angle":180,"flipped":true}]
    """.utf8)))
    guard case .group(let kids) = page.layers[0].kind else { Issue.record("no kids"); return }
    let ring = kids[0]
    // Concentric with the 400x400 artboard, despite being placed near its bottom.
    #expect(abs(ring.frame.midX - 200) < 0.01)
    #expect(abs(ring.frame.midY - 200) < 0.01)

    // And the glyphs land inside the artboard rather than being clipped away.
    guard case .text(let run) = ring.kind else { Issue.record("not text"); return }
    let box = TextOutline.path(run, in: CGRect(origin: .zero, size: ring.frame.size))!.boundingBoxOfPath
    #expect(box.minY + ring.frame.minY >= 0)
    #expect(box.maxY + ring.frame.minY <= 400)
}

// MARK: - Adding points to a path

private func curvedTestPath() -> VectorPath {
    let cg = CGMutablePath()
    cg.move(to: CGPoint(x: 0, y: 200))
    cg.addCurve(to: CGPoint(x: 400, y: 200),
                control1: CGPoint(x: 60, y: 0), control2: CGPoint(x: 340, y: 0))
    return VectorPath(cgPath: cg)
}

@Test func insertingAPointDoesNotMoveTheCurve() {
    var vp = curvedTestPath()
    let before = (0...40).map { VectorPath.evaluate(vp.points[0], vp.points[1], CGFloat($0) / 40) }

    let made = vp.insertPoint(onSegment: 0, at: 0.37)
    #expect(made == 1)
    #expect(vp.points.count == 3)

    // Walk both halves and compare against the original curve. Splitting with
    // de Casteljau is exact, so adding a point must not nudge the shape at all.
    var after: [CGPoint] = []
    for s in 0...40 {
        let t = CGFloat(s) / 40
        // 0.37 of the original curve is now the whole of segment 0.
        let (seg, local) = t <= 0.37 ? (0, t / 0.37) : (1, (t - 0.37) / 0.63)
        guard let (a, b) = vp.segment(seg) else { Issue.record("missing segment"); return }
        after.append(VectorPath.evaluate(a, b, local))
    }
    for (u, v) in zip(before, after) {
        #expect(abs(u.x - v.x) < 0.01)
        #expect(abs(u.y - v.y) < 0.01)
    }
}

@Test func insertingOnAStraightSegmentKeepsItStraight() {
    var vp = VectorPath(cgPath: {
        let cg = CGMutablePath()
        cg.move(to: .zero)
        cg.addLine(to: CGPoint(x: 100, y: 0))
        return cg
    }())
    vp.insertPoint(onSegment: 0, at: 0.5)
    #expect(vp.points.count == 3)
    #expect(vp.points[1].point == CGPoint(x: 50, y: 0))
    // No handles invented, so the line doesn't develop a kink when it's next dragged.
    #expect(!vp.points[1].hasCurveTo)
    #expect(!vp.points[1].hasCurveFrom)
}

@Test func theInsertedPointLandsWhereYouClicked() {
    var vp = curvedTestPath()
    // Somewhere on the curve, found the way the canvas finds it.
    let target = VectorPath.evaluate(vp.points[0], vp.points[1], 0.7)
    guard let hit = vp.closestSegment(to: target, within: 50) else {
        Issue.record("no segment found"); return
    }
    guard let made = vp.insertPoint(onSegment: hit.index, at: hit.t) else {
        Issue.record("insert failed"); return
    }
    let placed = vp.points[made].point
    #expect(hypot(placed.x - target.x, placed.y - target.y) < 1)
}

@Test func insertingThenRemovingReturnsTheSamePath() {
    var vp = curvedTestPath()
    let before = (0...20).map { VectorPath.evaluate(vp.points[0], vp.points[1], CGFloat($0) / 20) }
    guard let made = vp.insertPoint(onSegment: 0, at: 0.5) else { Issue.record("no insert"); return }
    vp.removePoint(made)
    #expect(vp.points.count == 2)
    let after = (0...20).map { VectorPath.evaluate(vp.points[0], vp.points[1], CGFloat($0) / 20) }
    for (u, v) in zip(before, after) {
        #expect(abs(u.x - v.x) < 1)
        #expect(abs(u.y - v.y) < 1)
    }
}

@Test func centringPutsThePointHalfwayAlongTheSegment() {
    var vp = curvedTestPath()
    let expected = VectorPath.evaluate(vp.points[0], vp.points[1], 0.5)
    guard let made = vp.insertPoint(onSegment: 0, at: 0.5) else { Issue.record("no insert"); return }

    // On the curve, halfway between its neighbours along the path.
    #expect(hypot(vp.points[made].point.x - expected.x,
                  vp.points[made].point.y - expected.y) < 0.01)

    // Halfway means halfway: both new segments should be the same length.
    func arcLength(_ i: Int) -> CGFloat {
        guard let (a, b) = vp.segment(i) else { return 0 }
        var total: CGFloat = 0
        var last = VectorPath.evaluate(a, b, 0)
        for s in 1...64 {
            let q = VectorPath.evaluate(a, b, CGFloat(s) / 64)
            total += hypot(q.x - last.x, q.y - last.y)
            last = q
        }
        return total
    }
    let left = arcLength(0), right = arcLength(1)
    #expect(abs(left - right) / max(left, right) < 0.01)
}

@Test func centringOnAStraightSegmentIsTheExactMidpoint() {
    var vp = VectorPath(cgPath: {
        let cg = CGMutablePath()
        cg.move(to: CGPoint(x: 10, y: 20))
        cg.addLine(to: CGPoint(x: 110, y: 220))
        return cg
    }())
    vp.insertPoint(onSegment: 0, at: 0.5)
    #expect(vp.points[1].point == CGPoint(x: 60, y: 120))
}

// MARK: - Simplify

/// A circle drawn with far more points than it needs, as traced artwork arrives.
private func overSampledCircle(points n: Int, radius r: CGFloat) -> VectorPath {
    let cg = CGMutablePath()
    for i in 0..<n {
        let a = CGFloat(i) / CGFloat(n) * 2 * .pi
        let p = CGPoint(x: 200 + r * cos(a), y: 200 + r * sin(a))
        i == 0 ? cg.move(to: p) : cg.addLine(to: p)
    }
    cg.closeSubpath()
    return VectorPath(cgPath: cg)
}

/// Worst distance from `path` to the nearest point of `reference`.
private func maxDeviation(_ path: VectorPath, from reference: VectorPath) -> CGFloat {
    var ref: [CGPoint] = []
    for i in 0..<reference.segmentCount {
        guard let (a, b) = reference.segment(i) else { continue }
        for s in 0..<24 { ref.append(VectorPath.evaluate(a, b, CGFloat(s) / 24)) }
    }
    var worst: CGFloat = 0
    for i in 0..<path.segmentCount {
        guard let (a, b) = path.segment(i) else { continue }
        for s in 0...24 {
            let q = VectorPath.evaluate(a, b, CGFloat(s) / 24)
            let nearest = ref.map { hypot($0.x - q.x, $0.y - q.y) }.min() ?? 0
            worst = max(worst, nearest)
        }
    }
    return worst
}

@Test func simplifyDropsPointsAndStaysWithinTolerance() {
    let original = overSampledCircle(points: 120, radius: 150)
    var vp = original
    vp.simplify(tolerance: 1)

    #expect(vp.points.count < 20)                 // 120 points is ~15x what a circle needs
    #expect(vp.points.count >= 4)
    #expect(maxDeviation(vp, from: original) <= 1.5)
}

@Test func aTighterToleranceKeepsMorePoints() {
    let original = overSampledCircle(points: 200, radius: 300)
    var loose = original, tight = original
    loose.simplify(tolerance: 8)
    tight.simplify(tolerance: 0.25)
    #expect(tight.points.count > loose.points.count)
    #expect(maxDeviation(tight, from: original) < maxDeviation(loose, from: original))
}

@Test func simplifyKeepsCorners() {
    // A square traced with many points down each side. Rounding the corners off is
    // not a simpler square, it's a different shape.
    let cg = CGMutablePath()
    let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0),
                   CGPoint(x: 300, y: 300), CGPoint(x: 0, y: 300)]
    cg.move(to: corners[0])
    for i in 0..<4 {
        let a = corners[i], b = corners[(i + 1) % 4]
        for s in 1...20 {
            let t = CGFloat(s) / 20
            cg.addLine(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
    }
    cg.closeSubpath()
    var vp = VectorPath(cgPath: cg)
    let before = vp.points.count
    vp.simplify(tolerance: 1)

    #expect(vp.points.count < before / 4)
    // Every original corner still has a point sitting on it.
    for c in corners {
        let hit = vp.points.contains { hypot($0.point.x - c.x, $0.point.y - c.y) < 2 }
        #expect(hit, "corner \(c) was rounded off")
    }
}

@Test func simplifyLeavesAnAlreadyMinimalPathAlone() {
    // Four points for a circle is already optimal; it must not grow or drift.
    let cg = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 200), transform: nil)
    let original = VectorPath(cgPath: cg)
    var vp = original
    vp.simplify(tolerance: 1)
    #expect(vp.points.count <= original.points.count)
    #expect(maxDeviation(vp, from: original) <= 1.5)
}

@Test func simplifyCommandReportsRealNumbers() {
    var page = Page(name: "p")
    var l = Layer(kind: .path(overSampledCircle(points: 120, radius: 150).cgPath(), closed: true))
    l.name = "traced"
    l.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    page.layers = [l]

    let run = page.run(DocumentCommand.decodeList(Data(#"[{"op":"simplify","name":"traced","tolerance":1}]"#.utf8)))
    // The report has to carry counts. "Simplify: 1 layer" would let a model claim a
    // saving it never made.
    #expect(run.report.contains("120 points"))
    #expect(run.report.contains("fewer"))
    #expect(page.layers[0].pointCount ?? 0 < 20)
}

@Test func detailScalesWithTheLayerSoOneNumberSuitsAnyShape() {
    func pointsAfter(detail: Double, radius: CGFloat, size: CGFloat) -> Int {
        var page = Page(name: "p")
        var l = Layer(kind: .path(overSampledCircle(points: 200, radius: radius).cgPath(), closed: true))
        l.name = "t"
        l.frame = CGRect(x: 0, y: 0, width: size, height: size)
        page.layers = [l]
        _ = page.run([.simplify(LayerQuery(), tolerance: nil, detail: detail)])
        return page.layers[0].pointCount ?? 0
    }
    // Same detail on a small icon and a big coin should give a similar result.
    let small = pointsAfter(detail: 0.5, radius: 20, size: 40)
    let large = pointsAfter(detail: 0.5, radius: 1000, size: 2000)
    #expect(abs(small - large) <= 4)

    // And higher detail must keep more.
    #expect(pointsAfter(detail: 0.95, radius: 300, size: 600)
            >= pointsAfter(detail: 0.3, radius: 300, size: 600))
}

@Test func describeShowsPointCountsSoTheModelCanTargetTheHeavyLayers() {
    var page = Page(name: "p")
    var heavy = Layer(kind: .path(overSampledCircle(points: 120, radius: 150).cgPath(), closed: true))
    heavy.name = "traced"
    heavy.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    var light = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    light.name = "box"
    light.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    page.layers = [heavy, light]

    let described = page.describe()
    #expect(described.contains("120 points"))
    // A four-point rectangle isn't worth the noise.
    #expect(!described.contains("4 points"))
}

@Test func layersCanBeSelectedByPointCount() {
    var page = Page(name: "p")
    var heavy = Layer(kind: .path(overSampledCircle(points: 120, radius: 150).cgPath(), closed: true))
    heavy.name = "traced"
    heavy.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    var light = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 50, height: 50), transform: nil), closed: true))
    light.name = "clean"
    light.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
    page.layers = [heavy, light]
    let cleanBefore = light.pointCount

    // What the model is shown ("120 points") has to be something it can act on.
    let run = page.run(DocumentCommand.decodeList(Data("""
    [{"op":"simplify","type":"path","minPoints":80,"detail":0.5}]
    """.utf8)))
    #expect(run.report.contains("1 layer"))
    #expect(page.layers[0].pointCount ?? 0 < 30)               // the traced one shrank
    #expect(page.layers[1].pointCount == cleanBefore)          // the clean one untouched
}

// MARK: - Point type

@Test func convertingToStraightDropsTheHandles() {
    var vp = curvedTestPath()
    vp.points[0].convert(to: .straight, previous: nil, next: vp.points[1].point)
    #expect(vp.points[0].isCorner)
    #expect(vp.points[0].mode == .straight)
}

@Test func convertingACornerToSmoothInventsHandlesAlongThePath() {
    // A corner between two straight runs.
    var vp = VectorPath(cgPath: {
        let cg = CGMutablePath()
        cg.move(to: CGPoint(x: 0, y: 0))
        cg.addLine(to: CGPoint(x: 100, y: 0))
        cg.addLine(to: CGPoint(x: 100, y: 100))
        return cg
    }())
    #expect(vp.points[1].isCorner)
    vp.points[1].convert(to: .mirrored, previous: vp.points[0].point, next: vp.points[2].point)

    #expect(!vp.points[1].isCorner)
    #expect(vp.points[1].mode == .mirrored)
    // Mirrored means the handles are equal and opposite about the anchor.
    let p = vp.points[1]
    let out = CGPoint(x: p.curveFrom.x - p.point.x, y: p.curveFrom.y - p.point.y)
    let into = CGPoint(x: p.curveTo.x - p.point.x, y: p.curveTo.y - p.point.y)
    #expect(abs(out.x + into.x) < 0.01)
    #expect(abs(out.y + into.y) < 0.01)
}

@Test func mirroredHandlesStayOppositeWhenOneIsDragged() {
    var vp = curvedTestPath()
    vp.points[0].mode = .mirrored
    vp.points[0].setHandle(out: true, to: CGPoint(x: 40, y: 40))
    let p = vp.points[0]
    let out = CGPoint(x: p.curveFrom.x - p.point.x, y: p.curveFrom.y - p.point.y)
    let into = CGPoint(x: p.curveTo.x - p.point.x, y: p.curveTo.y - p.point.y)
    #expect(abs(out.x + into.x) < 0.01)
    #expect(abs(out.y + into.y) < 0.01)
    #expect(abs(hypot(out.x, out.y) - hypot(into.x, into.y)) < 0.01)
}

@Test func asymmetricKeepsHandlesInLineButDifferentLengths() {
    var vp = curvedTestPath()
    var p = vp.points[0]
    p.mode = .asymmetric
    p.curveTo = CGPoint(x: p.point.x - 10, y: p.point.y)
    p.hasCurveTo = true
    p.setHandle(out: true, to: CGPoint(x: p.point.x + 90, y: p.point.y + 90))
    let out = CGPoint(x: p.curveFrom.x - p.point.x, y: p.curveFrom.y - p.point.y)
    let into = CGPoint(x: p.curveTo.x - p.point.x, y: p.curveTo.y - p.point.y)
    // Collinear and opposite...
    let cross = out.x * into.y - out.y * into.x
    #expect(abs(cross) < 0.01)
    // ...but the incoming handle kept its own length.
    #expect(abs(hypot(into.x, into.y) - 10) < 0.01)
}

@Test func alignedIsNotSilentlyTurnedBackIntoMirrored() {
    // The bug Adam hit: Aligned and Mirrored behaved identically. Choosing Aligned on
    // a point whose handles are the same length produced geometry indistinguishable
    // from Mirrored, and the type was re-guessed from that geometry on every rebuild.
    // A middle point, so it has handles on both sides — the case where Mirrored and
    // Aligned are distinguishable at all.
    let cg = CGMutablePath()
    cg.move(to: CGPoint(x: 0, y: 200))
    cg.addCurve(to: CGPoint(x: 200, y: 100), control1: CGPoint(x: 60, y: 200),
                control2: CGPoint(x: 160, y: 100))
    cg.addCurve(to: CGPoint(x: 400, y: 200), control1: CGPoint(x: 240, y: 100),
                control2: CGPoint(x: 340, y: 200))
    var vp = VectorPath(cgPath: cg)
    // Handles equal and opposite about the middle point: geometrically Mirrored.
    #expect(vp.points[1].mode == .mirrored)

    vp.points[1].mode = .asymmetric
    let round = VectorPath(cgPath: vp.cgPath(), modes: vp.points.map(\.mode))
    #expect(round.points[1].mode == .asymmetric)

    // Inference alone can't tell them apart, which is why the modes have to travel.
    #expect(VectorPath(cgPath: vp.cgPath()).points[1].mode == .mirrored)
}

@Test func alignedKeepsTheOtherHandlesLengthWhileMirroredDoesNot() {
    func drag(_ mode: CurveMode) -> (moved: CGFloat, other: CGFloat) {
        var p = VectorPoint(CGPoint(x: 100, y: 100))
        p.curveFrom = CGPoint(x: 140, y: 100); p.hasCurveFrom = true
        p.curveTo = CGPoint(x: 90, y: 100); p.hasCurveTo = true      // 40 out, 10 in
        p.mode = mode
        p.setHandle(out: true, to: CGPoint(x: 100, y: 180))          // drag out to 80
        return (hypot(p.curveFrom.x - p.point.x, p.curveFrom.y - p.point.y),
                hypot(p.curveTo.x - p.point.x, p.curveTo.y - p.point.y))
    }
    let aligned = drag(.asymmetric)
    #expect(abs(aligned.moved - 80) < 0.01)
    #expect(abs(aligned.other - 10) < 0.01)      // short side keeps its length...

    let mirrored = drag(.mirrored)
    #expect(abs(mirrored.moved - 80) < 0.01)
    #expect(abs(mirrored.other - 80) < 0.01)     // ...where mirrored matches it
}

@Test func pointTypesSurviveSavingAndReopening() throws {
    var vp = curvedTestPath()
    vp.points[0].mode = .asymmetric
    vp.points[1].mode = .disconnected

    var l = Layer(kind: .path(vp.cgPath(), closed: false))
    l.name = "p"
    l.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    l.curveModes = vp.points.map(\.mode)
    var page = Page(name: "Page 1")
    page.layers = [l]
    var doc = Document()
    doc.pages = [page]

    let (back, _) = try AcmplcFile.read(AcmplcFile.write(document: doc, images: [:]))
    #expect(back.pages[0].layers[0].curveModes == [.asymmetric, .disconnected])
}

@Test func changingOnlyThePointTypeCountsAsAChange() {
    // Mirrored to Aligned moves nothing. If the signature ignores it, the edit is
    // discarded as a no-op and the choice never lands.
    var l = Layer(kind: .path(curvedTestPath().cgPath(), closed: false))
    l.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    l.curveModes = [.mirrored, .mirrored]
    let before = l.contentSignature
    l.curveModes = [.asymmetric, .mirrored]
    #expect(l.contentSignature != before)
}

// MARK: - Masks

/// Adam's arrangement: a circle underneath marked as the mask, a bitmap above it.
private func maskedGroup() -> Layer {
    var circle = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 200),
                                          transform: nil), closed: true))
    circle.name = "Circle"
    circle.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    circle.hasClippingMask = true

    var photo = Layer(kind: .bitmap(imageRef: "photo.png"))
    photo.name = "Photo"
    photo.frame = CGRect(x: -50, y: -50, width: 400, height: 400)

    var group = Layer(kind: .group([circle, photo]))   // mask first: it clips what's above
    group.name = "Masked"
    group.frame = CGRect(x: 100, y: 100, width: 200, height: 200)
    return group
}

@Test func aMaskClipsTheLayersAboveItAndIsNotItselfPainted() {
    var page = Page(name: "p")
    page.layers = [maskedGroup()]
    let drawables = Compose.flatten(page.layers)

    // The circle defines the clip rather than being drawn.
    #expect(drawables.count == 1)
    let photo = try! #require(drawables.first)
    #expect(photo.layer.name == "Photo")
    #expect(photo.clip != nil)

    // And the clip is the circle, in page coordinates.
    let box = photo.clip!.boundingBoxOfPath
    #expect(abs(box.width - 200) < 1)
    #expect(abs(box.height - 200) < 1)
}

@Test func ignoreMaskExemptsALayerFromTheClip() {
    var group = maskedGroup()
    guard case .group(var kids) = group.kind else { Issue.record("no kids"); return }
    kids[1].breaksMaskChain = true
    group.kind = .group(kids)

    var page = Page(name: "p")
    page.layers = [group]
    let drawables = Compose.flatten(page.layers)
    #expect(drawables.first?.clip == nil)
}

@Test func resizingAGroupScalesEverythingInsideAtTheSameRate() {
    // The old Sketch behaviour Adam wants kept: drag the group, the mask and its
    // contents scale together rather than the group's box sliding over fixed art.
    var group = maskedGroup()
    group.resize(to: CGSize(width: 400, height: 400))       // 2x

    guard case .group(let kids) = group.kind else { Issue.record("no kids"); return }
    let circle = kids[0], photo = kids[1]
    #expect(circle.frame.size == CGSize(width: 400, height: 400))
    #expect(photo.frame == CGRect(x: -100, y: -100, width: 800, height: 800))

    // The mask geometry scaled too, not just its frame — otherwise the clip would
    // stay the old size and crop the enlarged photo to a small circle.
    guard case .path(let p, _) = circle.kind else { Issue.record("not a path"); return }
    let box = p.boundingBoxOfPath
    #expect(abs(box.width - 400) < 1)
    #expect(abs(box.height - 400) < 1)
}

@Test func aMaskSurvivesSavingAndReopening() throws {
    var page = Page(name: "Page 1")
    page.layers = [maskedGroup()]
    var doc = Document()
    doc.pages = [page]

    let (back, _) = try AcmplcFile.read(AcmplcFile.write(document: doc, images: [:]))
    guard case .group(let kids) = back.pages[0].layers[0].kind else {
        Issue.record("group lost"); return
    }
    #expect(kids[0].hasClippingMask)
}

@Test func aShapeDrawnOnTopStillMasksWhatWasBelowIt() {
    // You draw the circle last, so it's above the photo — where a mask has nothing to
    // clip. Marking it must not be a no-op.
    var photo = Layer(kind: .bitmap(imageRef: "photo.png"))
    photo.name = "Photo"
    photo.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
    var circle = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 200),
                                          transform: nil), closed: true))
    circle.name = "Circle"
    circle.frame = CGRect(x: 0, y: 0, width: 200, height: 200)

    var page = Page(name: "p")
    page.layers = [photo, circle]           // circle on top, as drawn

    page.updateLayer(circle.id) { $0.hasClippingMask = true }
    page.sendToBack([circle.id])            // what toggleMask does

    #expect(page.layers[0].name == "Circle")
    let drawables = Compose.flatten(page.layers)
    #expect(drawables.count == 1)
    #expect(drawables[0].layer.name == "Photo")
    #expect(drawables[0].clip != nil)
}

@Test func theDigitKeysMapStraightOntoThePointTypes() {
    // The canvas turns keyCodes 18...21 into CurveMode(rawValue: code - 17). That only
    // stays correct while the raw values are 1...4 in the inspector's order — pin it,
    // because reordering the enum would silently rewire the keyboard.
    #expect(CurveMode(rawValue: 1) == .straight)
    #expect(CurveMode(rawValue: 2) == .mirrored)
    #expect(CurveMode(rawValue: 3) == .asymmetric)     // "Aligned"
    #expect(CurveMode(rawValue: 4) == .disconnected)   // "Free"
    #expect(CurveMode.allCases.map(\.rawValue) == [1, 2, 3, 4])
}
