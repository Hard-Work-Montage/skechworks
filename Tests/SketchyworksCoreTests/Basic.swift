import CoreGraphics
import Foundation
import Testing

@testable import SketchyworksCore

// The polyglot is the load-bearing claim of this whole format, so it gets tested
// from both directions on every build.

@Test func zipRoundTrips() throws {
    let entries = [
        ZipEntry(name: "document.json", data: Data(#"{"format":"sw"}"#.utf8)),
        ZipEntry(name: "exports/page.svg", data: Data(String(repeating: "<path/>", count: 500).utf8)),
    ]
    let back = try Zip.read(Zip.write(entries))
    #expect(back.count == 2)
    #expect(String(decoding: back["document.json"]!, as: UTF8.self) == #"{"format":"sw"}"#)
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

    let data = try SketchyworksFile.write(document: doc, images: [:])

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

    let (back, _) = try SketchyworksFile.read(try SketchyworksFile.write(document: doc, images: [:]))
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
    #expect(throws: (any Error).self) { try SketchyworksFile.read(png) }
}

@Test func aSketchArchiveIsRefusedNotSwallowed() throws {
    // A .sketch is also a zip with a document.json and a "pages" array. Parsing one
    // as a Sketchyworks document "succeeded" with a hollow 1-page/0-layer document,
    // so the app never fell through to the Sketch reader and showed blank pages.
    let sketchDocJSON = #"{"_class":"document","pages":[{"_class":"MSJSONFileReference","_ref":"pages/ABC"}]}"#
    let zip = Zip.write([
        ZipEntry(name: "document.json", data: Data(sketchDocJSON.utf8)),
        ZipEntry(name: "pages/ABC.json", data: Data(#"{"_class":"page"}"#.utf8)),
    ])
    #expect(throws: SketchyworksFile.ReadError.self) { try SketchyworksFile.read(zip) }

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fake-\(UUID().uuidString).sketch")
    try zip.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: SketchyworksFile.ReadError.self) { _ = try DocumentSource.sw(url: url) }
}

@Test func aDefaultSketchArtboardImportsAsAWhiteCardThatExportsTransparent() throws {
    // Sketch presents every artboard as a white card; hasBackgroundColor only marks
    // a custom colour. Importing only the custom case left default artboards with no
    // plate — artwork floating on the dark canvas.
    let page = #"{"_class":"page","name":"P","layers":[{"_class":"artboard","name":"Board","frame":{"x":0,"y":0,"width":100,"height":100},"layers":[]}]}"#
    let zip = Zip.write([
        ZipEntry(name: "document.json", data: Data(#"{"_class":"document","pages":[{"_class":"MSJSONFileReference","_ref":"pages/P1"}]}"#.utf8)),
        ZipEntry(name: "pages/P1.json", data: Data(page.utf8)),
    ])
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fixture-\(UUID().uuidString).sketch")
    try zip.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    var reader = SketchReader()
    let doc = try reader.read(url: url)
    let board = try #require(doc.pages.first?.layers.first)
    #expect(board.isArtboard)
    let bg = try #require(board.backgroundColor)
    #expect(bg.r == 1 && bg.g == 1 && bg.b == 1 && bg.a == 1)
    #expect(board.backgroundInExport == false)
}

@Test func aSketchFrameImportsAsAnArtboardWithItsFillAsTheCard() throws {
    // Sketch Frames (groupBehavior != 0) replaced artboards; the card colour is a
    // style fill. Imported as plain groups they lost the card, the label and the
    // clip, so neighbouring panels visually merged on the canvas.
    let fill = #"{"_class":"fill","isEnabled":true,"fillType":0,"color":{"_class":"color","alpha":1,"red":0.9,"green":0.8,"blue":0.7}}"#
    let page = """
    {"_class":"page","name":"P","layers":[
      {"_class":"group","name":"Panel","groupBehavior":1,
       "frame":{"x":0,"y":0,"width":100,"height":100},
       "style":{"fills":[\(fill)]},"layers":[]},
      {"_class":"group","name":"Plain","groupBehavior":0,
       "frame":{"x":0,"y":0,"width":50,"height":50},"layers":[]}
    ]}
    """
    let zip = Zip.write([
        ZipEntry(name: "document.json", data: Data(#"{"_class":"document","pages":[{"_class":"MSJSONFileReference","_ref":"pages/P1"}]}"#.utf8)),
        ZipEntry(name: "pages/P1.json", data: Data(page.utf8)),
    ])
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fixture-\(UUID().uuidString).sketch")
    try zip.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    var reader = SketchReader()
    let doc = try reader.read(url: url)
    let frame = try #require(doc.pages.first?.layers.first)
    #expect(frame.isArtboard)
    let bg = try #require(frame.backgroundColor)
    #expect(abs(bg.r - 0.9) < 0.001 && abs(bg.g - 0.8) < 0.001 && abs(bg.b - 0.7) < 0.001)
    #expect(frame.style.fills.isEmpty)

    let plain = try #require(doc.pages.first?.layers.last)
    #expect(!plain.isArtboard)
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
    // document round-trips through .sw.png.
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

    let (back, _) = try SketchyworksFile.read(try SketchyworksFile.write(document: doc, images: [:]))
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
    let encoded = try SketchyworksFile.encodeClipboard(layers: [group], images: ["images/abc.png": bytes])
    let back = try #require(SketchyworksFile.decodeClipboard(encoded))

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
    #expect(DocumentKind.isDocument(URL(fileURLWithPath: "/x/coin.sw.png")))
    #expect(DocumentKind.isDocument(URL(fileURLWithPath: "/x/coin.sw")))
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

@Test func flipMirrorsInPlaceAndDecodesEveryWayAModelSaysIt() {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 40, height: 20), transform: nil), closed: true))
    l.name = "Arrow"
    var page = Page(name: "p")
    page.layers = [l]

    // An empty query means "the selection" — name the layer, the way a model would.
    var q = LayerQuery()
    q.name = "Arrow"
    _ = page.run([.flip(q, axis: "horizontal")])
    #expect(page.layers[0].flipH == true)
    _ = page.run([.flip(q, axis: "horizontal")])
    #expect(page.layers[0].flipH == false)      // a mirror of a mirror is the original
    _ = page.run([.flip(q, axis: "vertical")])
    #expect(page.layers[0].flipV == true)

    let cmds = DocumentCommand.decodeList(Data("""
    {"commands":[
      {"op":"flip","axis":"vertical"},
      {"op":"flipHorizontal"},
      {"op":"mirror","direction":"y"}
    ]}
    """.utf8))
    #expect(cmds.count == 3)
    guard case .flip(_, let a0) = cmds[0], case .flip(_, let a1) = cmds[1] else {
        Issue.record("expected flips"); return
    }
    #expect(a0 == "vertical")
    #expect(a1 == "horizontal")
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

@Test func setFillReadsTheColourWhereverTheModelPutIt() {
    // "Make every layer white" produced {"op":"setFill","fill":"#ffffff"} — but
    // "fill" is a selector key, so the colour landed in the query and the command
    // decoded as "recolour to nothing" and was dropped.
    let json = """
    {"commands":[
      {"op":"setFill","fill":"#ffffff"},
      {"op":"setFill","fill":"#0c0a0b","color":"#ffffff"},
      {"op":"setFill","color":{"hex":"#ff0000"}},
      {"op":"setStroke","stroke":"#123456"}
    ]}
    """
    let cmds = DocumentCommand.decodeList(Data(json.utf8))
    #expect(cmds.count == 4)

    guard case .setFill(let q1, let h1) = cmds[0] else { Issue.record("expected setFill"); return }
    #expect(h1 == "#ffffff")
    #expect(q1.fill == nil)                 // the colour, not a filter

    guard case .setFill(let q2, let h2) = cmds[1] else { Issue.record("expected setFill"); return }
    #expect(h2 == "#ffffff")
    #expect(q2.fill == "#0c0a0b")           // explicit colour present: "fill" stays a selector

    guard case .setFill(_, let h3) = cmds[2] else { Issue.record("expected setFill"); return }
    #expect(h3 == "#ff0000")                // colour wrapped in an object

    guard case .setStroke(let q4, let h4, _) = cmds[3] else { Issue.record("expected setStroke"); return }
    #expect(h4 == "#123456")
    #expect(q4.stroke == nil)
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

@Test func hexParsesEveryFormAColourArrivesIn() {
    // #rrggbb, the ordinary case, with and without the hash.
    #expect(Color(hex: "#A9A9A9")!.matches(Color(r: 169/255, g: 169/255, b: 169/255, a: 1)))
    #expect(Color(hex: "a9a9a9")!.matches(Color(hex: "#A9A9A9")!))
    // Shorthand, as CSS writes it.
    #expect(Color(hex: "#f00")!.matches(Color(r: 1, g: 0, b: 0, a: 1)))
    // Eight digits carry their own alpha and must win over the parameter.
    #expect(abs(Color(hex: "#00000080", alpha: 1)!.a - 128.0/255.0) < 1e-9)
    // Six digits don't, so the parameter is what's left of the old colour's alpha —
    // typing a new hex into the field shouldn't silently make a translucent fill opaque.
    #expect(Color(hex: "#000000", alpha: 0.25)!.a == 0.25)
    #expect(Color(hex: "#ffffff")!.matches(Color(r: 1, g: 1, b: 1, a: 1)))

    for junk in ["", "#", "nope", "#12345", "#gggggg", "#1234567", "  "] {
        #expect(Color(hex: junk) == nil, "\"\(junk)\" should not parse")
    }
    // Surrounding whitespace survives a copy-paste and shouldn't.
    #expect(Color(hex: "  #A9A9A9\n")!.matches(Color(hex: "#a9a9a9")!))
}

@Test func colourEqualityIgnoresNothingThatMatters() {
    let c = Color(r: 0.5, g: 0.5, b: 0.5, a: 1)
    // Same rgb, different alpha, is a different colour. Comparing on `hex` alone —
    // which is #rrggbb — would call these equal and drop the change.
    #expect(!c.matches(Color(r: 0.5, g: 0.5, b: 0.5, a: 0.5)))
    // Below what the file stores, so it isn't an edit.
    #expect(c.matches(Color(r: 0.5001, g: 0.5, b: 0.5, a: 1)))
}

/// Every editable, non-geometric property, one per row.
///
/// The signature has silently discarded an edit seven times — point types, masks,
/// shadows, rotation, erase, and twice on fills — each found only because something
/// stopped working in the app. Each fix added one field and left the next gap in
/// place. This is the standing list: adding an editable property means adding a row,
/// and the row fails until the signature can see it.
@Test func contentSignatureSeesEveryEditableProperty() {
    var base = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    base.id = "x"
    base.name = "before"
    base.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    base.style.fills = [Fill(paint: .color(Color(r: 1, g: 0, b: 0, a: 1))),
                        Fill(paint: .color(Color(r: 0, g: 1, b: 0, a: 1)))]
    var border = Border()
    border.color = .black
    border.thickness = 1
    base.style.borders = [border]
    base.style.shadows = [Shadow()]

    var gradient = Gradient()
    gradient.stops = [(position: 0, color: .black), (position: 1, color: Color(r: 1, g: 1, b: 1, a: 1))]

    let edits: [(String, (inout Layer) -> Void)] = [
        ("rename", { $0.name = "after" }),
        ("move", { $0.frame.origin.x += 5 }),
        ("resize", { $0.frame.size.width += 5 }),
        ("hide", { $0.isVisible = false }),
        ("layer opacity", { $0.style.opacity = 0.5 }),
        ("rotate", { $0.rotation = 12.5 }),
        // A hair under a degree: rotation used to be rounded to whole degrees here,
        // so nudging a layer round did nothing until you passed the next integer.
        ("rotate by a fraction of a degree", { $0.rotation = 0.4 }),
        ("first fill colour", { $0.style.fills[0].paint = .color(Color(r: 0, g: 0, b: 1, a: 1)) }),
        // Only the first fill was ever in the signature.
        ("second fill colour", { $0.style.fills[1].paint = .color(Color(r: 0, g: 0, b: 1, a: 1)) }),
        // `hex` is #rrggbb; alpha travels separately and was dropped.
        ("fill alpha", { $0.style.fills[0].paint = .color(Color(r: 1, g: 0, b: 0, a: 0.5)) }),
        ("fill opacity", { $0.style.fills[0].opacity = 0.5 }),
        ("add a fill", { $0.style.fills.append(Fill(paint: .color(.black))) }),
        ("remove a fill", { $0.style.fills.removeLast() }),
        ("fill becomes a gradient", { $0.style.fills[0].paint = .gradient(gradient) }),
        ("gradient stop colour", {
            var g = gradient
            g.stops[0].color = Color(r: 0.5, g: 0.5, b: 0.5, a: 1)
            $0.style.fills[0].paint = .gradient(g)
        }),
        ("gradient direction", {
            var g = gradient
            g.to = CGPoint(x: 1, y: 1)
            $0.style.fills[0].paint = .gradient(g)
        }),
        ("border colour", { $0.style.borders[0].color = Color(r: 0, g: 0, b: 1, a: 1) }),
        ("border alpha", { $0.style.borders[0].color = Color(r: 0, g: 0, b: 0, a: 0.5) }),
        // Thickness was stored as Int, so 1pt to 1.5pt was invisible.
        ("fractional border thickness", { $0.style.borders[0].thickness = 1.5 }),
        ("border position", { $0.style.borders[0].position = .inside }),
        ("border dash", { $0.style.borders[0].dashPattern = [4, 2] }),
        ("add a border", { $0.style.borders.append(Border()) }),
        ("shadow colour", { $0.style.shadows[0].color = Color(r: 1, g: 0, b: 0, a: 1) }),
        ("shadow offset", { $0.style.shadows[0].offset = CGSize(width: 3, height: 3) }),
        ("shadow blur", { $0.style.shadows[0].blur = 20 }),
        ("shadow spread", { $0.style.shadows[0].spread = 4 }),
        ("add a shadow", { $0.style.shadows.append(Shadow()) }),
        ("mask", { $0.hasClippingMask = true }),
        ("break the mask chain", { $0.breaksMaskChain = true }),
        ("erase", { $0.erased = [EraseStroke(points: [.zero], radius: 4, softness: 0.5)] }),
    ]

    for (what, apply) in edits {
        var changed = base
        apply(&changed)
        #expect(changed.contentSignature != base.contentSignature,
                "changing \(what) left the signature identical, so the edit is discarded")
    }

    var untouched = base
    untouched.name = base.name
    #expect(untouched.contentSignature == base.contentSignature)
}

@Test func opacityArrivesInEverySpellingModelsUse() {
    // Four models, one request — "make every text layer 50% opacity" — and four
    // spellings of the answer. The decoder took only JSON numbers, so three of the
    // four dropped the command while the model's "done" stood unchallenged.
    func opacity(_ value: Any) -> Double? {
        guard case .setOpacity(_, let v)? = DocumentCommand.decode(
            ["op": "setOpacity", "value": value] as [String: Any]) else { return nil }
        return v
    }
    #expect(opacity(50) == 0.5)
    #expect(opacity(0.5) == 0.5)
    #expect(opacity("50") == 0.5)
    #expect(opacity("50%") == 0.5)
    #expect(opacity("0.5") == 0.5)
    #expect(opacity("{0.5}") == 0.5)      // qwen3.5:4b, verbatim
    #expect(opacity(" 50 % ") == 0.5)
    // Refused, not guessed at. A command that silently becomes zero opacity makes
    // the layer vanish and reports success.
    #expect(opacity("half") == nil)
    #expect(opacity("") == nil)
}

@Test func numbersAreReadOutOfDecorationButNeverInvented() {
    #expect(number(in: "12") == 12)
    #expect(number(in: "12.5pt") == 12.5)
    #expect(number(in: "-4") == -4)
    #expect(number(in: "width: 300px") == 300)
    #expect(number(in: "#000000") == 0)     // hex is not a number; callers ask for hex as a string
    #expect(number(in: "abc") == nil)
    #expect(number(in: "") == nil)
    #expect(number(in: "-") == nil)
    #expect(number(in: ".") == nil)
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
    // A setFill with no colour anywhere. ({"op":"setFill","fill":"#..."} used to be
    // the example here, but that shape is real model output and now decodes with
    // "fill" read as the colour.)
    let reply = #"{"say":"Done!","commands":[{"op":"setFill","name":"Halo"}]}"#
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

    let data = try SketchyworksFile.write(document: doc, images: [:])
    let (back, _) = try SketchyworksFile.read(data)
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

    // By name, not by index: a new artboard goes to the BACK of the page, so which
    // slot each one is in isn't what this test is about.
    guard let older = page.layers.first(where: { $0.name == "back" }),
          let newer = page.layers.first(where: { $0.name == "Back" }),
          case .group(let oldKids) = older.kind,
          case .group(let newKids) = newer.kind else {
        Issue.record("expected two artboards"); return
    }
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

    let (back, _) = try SketchyworksFile.read(SketchyworksFile.write(document: doc, images: [:]))
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

@Test func theRatioLockSurvivesSavingAndRegistersAsAnEdit() throws {
    var l = Layer(kind: .bitmap(imageRef: "p.png"))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 50)
    #expect(l.constrainProportions)          // locked is the default

    let before = l.contentSignature
    l.constrainProportions = false
    #expect(l.contentSignature != before)    // the toggle must not be discarded as a no-op

    var page = Page(name: "p")
    page.layers = [l]
    var doc = Document()
    doc.pages = [page]
    let data = try SketchyworksFile.write(document: doc, images: ["p.png": Data([1])])
    let (back, _) = try SketchyworksFile.read(data)
    #expect(back.pages[0].layers[0].constrainProportions == false)
}

@Test func aMixedGroupsVisibleBoundsIncludeItsBitmaps() {
    // resolvedPath only merges vector children, so a group holding a bitmap and a
    // rect measured as just the rect — the selection box ignored the picture.
    var laptop = Layer(kind: .bitmap(imageRef: "laptop.png"))
    laptop.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
    var rect = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 260, height: 12), transform: nil), closed: true))
    rect.frame = CGRect(x: 20, y: 195, width: 260, height: 12)
    var group = Layer(kind: .group([laptop, rect]))
    group.frame = CGRect(x: 50, y: 60, width: 300, height: 207)

    let vb = Compose.visibleBounds(of: group)
    #expect(abs(vb.minX - 50) < 1)
    #expect(abs(vb.minY - 60) < 1)
    #expect(abs(vb.width - 300) < 1)     // the bitmap's width, not the rect's
    #expect(abs(vb.height - 207) < 1)
}

@Test func aMaskedGroupReportsTheClippedBoundsNotTheUnion() {
    let group = maskedGroup()
    #expect(group.containsClippingMask)

    // The photo alone spans 400×400; the circle clips the visible region to the
    // 200×200 it covers, at the group's position on the page.
    let vb = Compose.visibleBounds(of: group)
    #expect(abs(vb.minX - 100) < 1)
    #expect(abs(vb.minY - 100) < 1)
    #expect(abs(vb.width - 200) < 1)
    #expect(abs(vb.height - 200) < 1)
}

@Test func anUnmaskedGroupDoesNotClaimAClippingMask() {
    var plain = maskedGroup()
    if case .group(var kids) = plain.kind {
        kids[0].hasClippingMask = false
        plain.kind = .group(kids)
    }
    #expect(!plain.containsClippingMask)
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

    let (back, _) = try SketchyworksFile.read(SketchyworksFile.write(document: doc, images: [:]))
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

// MARK: - Reordering and reparenting

private func pageWithArtboardAndLooseImage() -> Page {
    var art = Layer(kind: .group([]))
    art.name = "Frame"
    art.isArtboard = true
    art.backgroundColor = Color(r: 1, g: 1, b: 1, a: 1)
    art.frame = CGRect(x: 500, y: 300, width: 400, height: 400)

    var photo = Layer(kind: .bitmap(imageRef: "etsy_01.png"))
    photo.name = "etsy_01"
    photo.frame = CGRect(x: 420, y: 250, width: 500, height: 500)   // overlapping, at page level

    var page = Page(name: "p")
    page.layers = [art, photo]
    return page
}

@Test func aLoneLayerInAnArtboardAlignsToTheBoard() {
    var desk = Layer(kind: .bitmap(imageRef: "desk.png"))
    desk.name = "Desk"
    desk.frame = CGRect(x: 300, y: 200, width: 200, height: 100)
    var board = Layer(kind: .group([desk]))
    board.name = "Panel"
    board.isArtboard = true
    board.frame = CGRect(x: 1000, y: 0, width: 800, height: 600)

    var loose = Layer(kind: .bitmap(imageRef: "loose.png"))
    loose.name = "Loose"
    loose.frame = CGRect(x: 50, y: 50, width: 60, height: 60)

    var page = Page(name: "p")
    page.layers = [board, loose]

    page.align([desk.id], to: .left)
    #expect(page.layer(desk.id)!.frame.origin.x == 0)          // hugs the board's left
    page.align([desk.id], to: .bottom)
    #expect(page.layer(desk.id)!.frame.origin.y == 500)        // 600 - 100
    page.align([desk.id], to: .horizontalCentre)
    #expect(page.layer(desk.id)!.frame.origin.x == 300)        // (800-200)/2

    // A loose layer has nothing to align to: unchanged.
    page.align([loose.id], to: .left)
    #expect(page.layer(loose.id)!.frame.origin == CGPoint(x: 50, y: 50))
}

@Test func aMarqueeCannotCatchArtClippedAwayByItsBoard() {
    // The bed's frame spills far outside Panel 2, across Panel 1. The board clips
    // the paint — hits have to clip the same way, or selecting in one panel grabs
    // a neighbouring panel's invisible overflow.
    var bed = Layer(kind: .bitmap(imageRef: "bed.png"))
    bed.name = "Bed"
    bed.frame = CGRect(x: -900, y: 100, width: 1400, height: 400)   // overflows left
    var board2 = Layer(kind: .group([bed]))
    board2.name = "Panel 2"
    board2.isArtboard = true
    board2.frame = CGRect(x: 1100, y: 0, width: 1000, height: 1000)

    var desk = Layer(kind: .bitmap(imageRef: "desk.png"))
    desk.name = "Desk"
    desk.frame = CGRect(x: 500, y: 100, width: 400, height: 400)
    var board1 = Layer(kind: .group([desk]))
    board1.name = "Panel 1"
    board1.isArtboard = true
    board1.frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    var page = Page(name: "p")
    page.layers = [board1, board2]

    // A marquee over Panel 1's desk: the desk, never the bed's clipped tail
    // (which covers the same page area, x 200–1100).
    let hits = page.marqueeHits(CGRect(x: 550, y: 150, width: 100, height: 100))
    #expect(hits == [desk.id])

    // Over Panel 2 itself, the bed is fair game.
    let inBoard2 = page.marqueeHits(CGRect(x: 1200, y: 150, width: 100, height: 100))
    #expect(inBoard2 == [bed.id])
}

@Test func anArtboardNeverReparentsIntoAnotherContainer() {
    // Pasting a copied board with another board selected reparented the copy INSIDE
    // it — the copy's plate covered everything, which read as the paste having
    // replaced the board and its contents.
    var page = pageWithArtboardAndLooseImage()
    var second = Layer(kind: .group([]))
    second.name = "Frame 2"
    second.isArtboard = true
    second.frame = CGRect(x: 950, y: 300, width: 400, height: 400)
    page.layers.append(second)
    let art = page.layers[0].id, photo = page.layers[1].id

    // A board alone: refused outright.
    let boardAlone = page.reparent([second.id], into: art, at: 0)
    #expect(boardAlone == false)
    #expect(page.layers.map(\.name) == ["Frame", "etsy_01", "Frame 2"])

    // A mixed batch: the art goes in, the board stays top-level.
    let mixed = page.reparent([photo, second.id], into: art, at: 0)
    #expect(mixed)
    #expect(page.children(of: art).map(\.name) == ["etsy_01"])
    #expect(page.layers.map(\.name) == ["Frame", "Frame 2"])

    // To the top level (no parent) a board still moves freely.
    let toTop = page.reparent([second.id], into: nil, at: 0)
    #expect(toTop)
}

@Test func draggingAnImageIntoAnArtboardMakesItAChildWithoutMovingIt() {
    var page = pageWithArtboardAndLooseImage()
    let art = page.layers[0].id, photo = page.layers[1].id
    let wasAt = page.absoluteOrigin(of: photo)!

    let moved = page.reparent([photo], into: art, at: 0)
    #expect(moved)

    // It's inside the artboard now...
    #expect(page.layers.count == 1)
    #expect(page.children(of: art).map(\.name) == ["etsy_01"])
    // ...and hasn't moved on the canvas. Frames are relative to the container, so a
    // move that ignored that would shift it by the artboard's offset.
    #expect(page.absoluteOrigin(of: photo) == wasAt)
    #expect(page.layer(photo)!.frame.origin == CGPoint(x: -80, y: -50))
}

@Test func anArtboardChildIsClippedToTheArtboard() {
    var page = pageWithArtboardAndLooseImage()
    let art = page.layers[0].id, photo = page.layers[1].id

    // Loose on the page: nothing crops it.
    #expect(Compose.flatten(page.layers).first(where: { $0.layer.id == photo })?.clip == nil)

    page.reparent([photo], into: art, at: 0)
    let inside = Compose.flatten(page.layers).first { $0.layer.id == photo }
    let clip = try! #require(inside?.clip)
    // Cropped to the artboard's edge — the whole point of dragging it in.
    let box = clip.boundingBoxOfPath
    #expect(abs(box.width - 400) < 1)
    #expect(abs(box.height - 400) < 1)
}

@Test func draggingOutOfAnArtboardAlsoKeepsItInPlace() {
    var page = pageWithArtboardAndLooseImage()
    let art = page.layers[0].id, photo = page.layers[1].id
    page.reparent([photo], into: art, at: 0)
    let wasAt = page.absoluteOrigin(of: photo)!

    let out = page.reparent([photo], into: nil, at: 0)
    #expect(out)
    #expect(page.layers.count == 2)
    #expect(page.absoluteOrigin(of: photo) == wasAt)
    #expect(page.layer(photo)!.frame.origin == CGPoint(x: 420, y: 250))
}

@Test func reorderingWithinAContainerLandsWhereYouDropped() {
    var page = Page(name: "p")
    page.layers = ["a", "b", "c", "d"].map { n in
        var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
        l.name = n
        return l
    }
    let d = page.layers[3].id
    page.reparent([d], into: nil, at: 1)
    #expect(page.layers.map(\.name) == ["a", "d", "b", "c"])

    // And moving down: the index has to account for the layer leaving its old slot.
    let a = page.layers[0].id
    page.reparent([a], into: nil, at: 3)
    #expect(page.layers.map(\.name) == ["d", "b", "a", "c"])
}

@Test func aGroupCannotBeDroppedInsideItself() {
    var page = Page(name: "p")
    var inner = Layer(kind: .group([]))
    inner.name = "Inner"
    inner.frame = CGRect(x: 10, y: 10, width: 50, height: 50)
    var outer = Layer(kind: .group([inner]))
    outer.name = "Outer"
    outer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    page.layers = [outer]

    // Would detach the whole subtree from the document.
    let intoChild = page.reparent([outer.id], into: inner.id, at: 0)
    let intoSelf = page.reparent([outer.id], into: outer.id, at: 0)
    #expect(!intoChild)
    #expect(!intoSelf)
    #expect(page.layers.count == 1)
    #expect(page.children(of: outer.id).count == 1)
}

@Test func layersCannotBeDroppedIntoSomethingThatIsNotAContainer() {
    var page = pageWithArtboardAndLooseImage()
    var rect = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    rect.name = "Rect"
    page.layers.append(rect)
    let intoPath = page.reparent([page.layers[1].id], into: rect.id, at: 0)
    #expect(!intoPath)
}

@Test func draggingSeveralLayersKeepsTheirOrder() {
    var page = Page(name: "p")
    page.layers = ["a", "b", "c", "d"].map { n in
        var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
        l.name = n
        return l
    }
    let b = page.layers[1].id, c = page.layers[2].id
    page.reparent([c, b], into: nil, at: 0)      // passed in the wrong order on purpose
    #expect(page.layers.map(\.name) == ["b", "c", "a", "d"])
}

// MARK: - Where a drop lands

private func nestedPage() -> (Page, art: String, kid: String, loose: String) {
    var kid = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    kid.name = "Inside"
    kid.frame = CGRect(x: 10, y: 10, width: 10, height: 10)

    var art = Layer(kind: .group([kid]))
    art.name = "Frame"
    art.isArtboard = true
    art.frame = CGRect(x: 100, y: 100, width: 400, height: 400)

    var loose = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    loose.name = "Loose"

    var page = Page(name: "p")
    page.layers = [art, loose]
    return (page, art.id, kid.id, loose.id)
}





@Test func onlyContainersReportThemselvesAsDropTargets() {
    let (page, art, kid, _) = nestedPage()
    #expect(page.layer(art)!.isContainer)
    #expect(!page.layer(kid)!.isContainer)
}


@Test func previewingADragMovesTheArtAndNotTheMaskAroundIt() {
    // Dragging the image inside a masked group: the image moves, the circle it's
    // clipped to does not. Shifting composed drawables took the clip along, so the
    // mask appeared to move and then snapped back when you let go.
    var ellipse = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 200),
                                           transform: nil), closed: true))
    ellipse.name = "Ellipse"
    ellipse.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    ellipse.hasClippingMask = true

    var photo = Layer(kind: .bitmap(imageRef: "p.png"))
    photo.name = "Photo"
    photo.frame = CGRect(x: 0, y: 0, width: 200, height: 200)

    var group = Layer(kind: .group([ellipse, photo]))
    group.frame = CGRect(x: 100, y: 100, width: 200, height: 200)

    let atRest = Compose.flatten([group])
    let restClip = try! #require(atRest.first?.clip).boundingBoxOfPath

    // Drag just the photo 60 to the left.
    let shift = CGAffineTransform(translationX: -60, y: 0)
    let moving = Compose.flatten([group], adjusting: [photo.id], live: shift)
    let movedClip = try! #require(moving.first?.clip).boundingBoxOfPath
    #expect(abs(movedClip.minX - restClip.minX) < 0.01)      // the mask stayed put

    // Dragging the whole group takes the mask with it, which is the other half.
    let together = Compose.flatten([group], adjusting: [group.id], live: shift)
    let groupClip = try! #require(together.first?.clip).boundingBoxOfPath
    #expect(abs(groupClip.minX - (restClip.minX - 60)) < 0.01)
}

@Test func previewingADragInsideAnArtboardKeepsTheArtboardEdgeStill() {
    var photo = Layer(kind: .bitmap(imageRef: "p.png"))
    photo.name = "Photo"
    photo.frame = CGRect(x: 20, y: 20, width: 100, height: 100)

    var art = Layer(kind: .group([photo]))
    art.name = "Frame"
    art.isArtboard = true
    art.frame = CGRect(x: 0, y: 0, width: 300, height: 300)

    let rest = try! #require(Compose.flatten([art]).first?.clip).boundingBoxOfPath
    let moved = try! #require(Compose.flatten([art], adjusting: [photo.id],
                                              live: CGAffineTransform(translationX: -60, y: 0))
                                .first?.clip).boundingBoxOfPath
    // The artboard isn't being dragged, so its crop must not slide with the photo.
    #expect(abs(moved.minX - rest.minX) < 0.01)
    #expect(abs(moved.width - rest.width) < 0.01)
}

@Test func markingAMaskCountsAsAChangeEvenWhenNothingMoves() {
    var l = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 10, height: 10),
                                     transform: nil), closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    let plain = l.contentSignature
    l.hasClippingMask = true
    #expect(l.contentSignature != plain)

    l.hasClippingMask = false
    l.breaksMaskChain = true
    #expect(l.contentSignature != plain)
}

// MARK: - Resizing

/// Adam's structure: artboard > group > image, so the image is two containers deep.
private func nestedImagePage() -> (Page, image: String) {
    var photo = Layer(kind: .bitmap(imageRef: "etsy_01.png"))
    photo.name = "etsy_01"
    photo.frame = CGRect(x: 50, y: 50, width: 200, height: 200)     // relative to the group

    var group = Layer(kind: .group([photo]))
    group.name = "Group"
    group.frame = CGRect(x: 100, y: 100, width: 300, height: 300)   // relative to the artboard

    var art = Layer(kind: .group([group]))
    art.name = "Frame"
    art.isArtboard = true
    art.frame = CGRect(x: 200, y: 200, width: 600, height: 600)

    var page = Page(name: "p")
    page.layers = [art]
    return (page, photo.id)
}

@Test func draggingTheBottomRightHandleGrowsFromTheTopLeftCorner() {
    // Nested two deep: the anchor is in page coordinates, the frame is relative to the
    // group. Mixing them threw the layer by the containers' combined offset, which
    // looked like the object re-centring itself on release.
    var (page, photo) = nestedImagePage()
    let before = page.absoluteOrigin(of: photo)!          // 200+100+50 = 350, 350
    #expect(before == CGPoint(x: 350, y: 350))

    // Grab the bottom-right handle: the anchor is the top-left, which must not move.
    page.scale([photo], about: before, by: CGSize(width: 2, height: 2),
               from: [photo: page.layer(photo)!.frame])

    #expect(page.absoluteOrigin(of: photo) == before)      // top-left pinned
    #expect(page.layer(photo)!.frame.size == CGSize(width: 400, height: 400))
}

@Test func draggingTheTopLeftHandleKeepsTheBottomRightCorner() {
    var (page, photo) = nestedImagePage()
    let start = page.layer(photo)!.frame
    let topLeft = page.absoluteOrigin(of: photo)!
    let bottomRight = CGPoint(x: topLeft.x + start.width, y: topLeft.y + start.height)

    page.scale([photo], about: bottomRight, by: CGSize(width: 0.5, height: 0.5),
               from: [photo: start])

    let now = page.absoluteOrigin(of: photo)!
    let size = page.layer(photo)!.frame.size
    #expect(size == CGSize(width: 100, height: 100))
    // The corner you weren't dragging stays put.
    #expect(abs(now.x + size.width - bottomRight.x) < 0.01)
    #expect(abs(now.y + size.height - bottomRight.y) < 0.01)
}

@Test func resizingATopLevelLayerStillWorks() {
    // The case that always worked, so the fix doesn't trade one for the other.
    var page = Page(name: "p")
    var l = Layer(kind: .bitmap(imageRef: "x.png"))
    l.frame = CGRect(x: 40, y: 40, width: 100, height: 100)
    page.layers = [l]

    page.scale([l.id], about: CGPoint(x: 40, y: 40), by: CGSize(width: 3, height: 3),
               from: [l.id: l.frame])
    #expect(page.layers[0].frame == CGRect(x: 40, y: 40, width: 300, height: 300))
}

@Test func resizingUsesTheFramesFromWhenTheDragStarted() {
    // Re-applying to the live frame instead of the starting one compounds the scale
    // across a gesture, so the layer runs away as you drag.
    var (page, photo) = nestedImagePage()
    let start = page.layer(photo)!.frame
    let anchor = page.absoluteOrigin(of: photo)!

    for s in [1.5, 2.0, 2.5] {
        page.scale([photo], about: anchor, by: CGSize(width: s, height: s), from: [photo: start])
    }
    #expect(page.layer(photo)!.frame.size == CGSize(width: 500, height: 500))
}

// MARK: - Group shadows

private func shadowedGroup() -> Layer {
    func dot(_ x: CGFloat) -> Layer {
        var l = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 60, height: 60),
                                         transform: nil), closed: true))
        l.frame = CGRect(x: x, y: 20, width: 60, height: 60)
        l.style.fills = [Fill(paint: .color(.black))]
        return l
    }
    var g = Layer(kind: .group([dot(10), dot(100)]))
    g.name = "Coin"
    g.frame = CGRect(x: 50, y: 50, width: 200, height: 120)
    var s = Shadow()
    s.offset = CGSize(width: 0, height: 4)
    s.blur = 8
    s.color = Color(r: 0, g: 0, b: 0, a: 0.25)
    g.style.shadows = [s]
    return g
}

@Test func aGroupShadowBracketsItsChildrenRatherThanLandingOnEachOne() {
    let drawables = Compose.flatten([shadowedGroup()])
    // Two children plus the two markers that bracket them.
    #expect(drawables.count == 4)
    #expect(drawables.first?.groupShadows?.count == 1)
    #expect(drawables.last?.endsGroup == true)
    // The children carry no shadow of their own — that would cast one child's shadow
    // onto the next instead of shadowing the group's silhouette.
    for d in drawables where !d.isMarker {
        #expect(d.style.shadows.isEmpty)
    }
}

@Test func aGroupWithoutAShadowIsNotBracketed() {
    var g = shadowedGroup()
    g.style.shadows = []
    let drawables = Compose.flatten([g])
    #expect(drawables.count == 2)
    #expect(drawables.allSatisfy { !$0.isMarker })
}

@Test func groupShadowsSurviveExportAsAFilter() {
    var page = Page(name: "p")
    page.layers = [shadowedGroup()]
    let svg = SVGWriter(images: [:]).svg(page: page)

    #expect(svg.contains("feDropShadow"))
    #expect(svg.contains("flood-opacity=\"0.25"))     // fmt writes 0.250
    #expect(svg.contains("dy=\"4\""))
    // The filter wraps the group, so it works from the combined silhouette.
    #expect(svg.contains("<g filter="))
    // Balanced, or the file simply won't open.
    #expect(svg.components(separatedBy: "<g filter=").count - 1
            == svg.components(separatedBy: "</g>").count - 1)
}

@Test func addingOrChangingAShadowCountsAsAChange() {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                     transform: nil), closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    let plain = l.contentSignature

    var s = Shadow()
    s.offset = CGSize(width: 0, height: 4)
    l.style.shadows = [s]
    let withShadow = l.contentSignature
    #expect(withShadow != plain)

    l.style.shadows[0].blur = 20
    #expect(l.contentSignature != withShadow)

    // Moving the light round changes the offset, which has to register too.
    l.style.shadows[0].offset = CGSize(width: 4, height: 0)
    #expect(l.contentSignature != withShadow)
}

// MARK: - What a click selects

@Test func clickingInsideAGroupResolvesToTheGroup() {
    // Adam's coin: artboard > Group > (Ellipse, etsy_01). Clicking the photo selects
    // the Group, because a group is one object.
    let (page, _) = nestedImagePage()
    guard case .group(let artKids) = page.layers[0].kind,
          case .group(let groupKids) = artKids[0].kind else {
        Issue.record("bad fixture"); return
    }
    let group = artKids[0], photo = groupKids[0]

    // The same walk the canvas does: outermost non-artboard ancestor.
    func target(_ leaf: Layer) -> String {
        for id in page.ancestors(of: leaf.id) {
            guard let a = page.layer(id) else { continue }
            if a.isArtboard { continue }
            return id
        }
        return leaf.id
    }
    #expect(target(photo) == group.id)
}

@Test func aLayerSittingDirectlyOnAnArtboardSelectsItself() {
    // Artboards must not swallow the click, or nothing on the page is reachable.
    var photo = Layer(kind: .bitmap(imageRef: "x.png"))
    photo.frame = CGRect(x: 10, y: 10, width: 50, height: 50)
    var art = Layer(kind: .group([photo]))
    art.isArtboard = true
    art.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    var page = Page(name: "p")
    page.layers = [art]

    var resolved = photo.id
    for id in page.ancestors(of: photo.id) {
        guard let a = page.layer(id), !a.isArtboard else { continue }
        resolved = id
        break
    }
    #expect(resolved == photo.id)
}

// MARK: - Keyboard shortcuts

@Test func noTwoShortcutsClaimTheSameKeystroke() {
    let clashes = Shortcuts.collisions
    for (a, b) in clashes {
        Issue.record("\(a.id) and \(b.id) both claim \(a.display)")
    }
    #expect(clashes.isEmpty)
}

@Test func everyShortcutIsNamedAndReachable() {
    for s in Shortcuts.all {
        #expect(!s.title.isEmpty)
        #expect(!s.key.isEmpty)
        #expect(!s.group.isEmpty)
    }
    // Ids are how menus and the canvas refer to entries; duplicates would silently
    // point two call sites at one definition.
    #expect(Set(Shortcuts.all.map(\.id)).count == Shortcuts.all.count)
}

@Test func canvasShortcutsCarryTheKeyCodesTheCanvasMatchesOn() {
    // A canvas shortcut with no key code is one the responder can't actually detect.
    for s in Shortcuts.all where s.context == .points && !s.key.contains("click") {
        if s.keyCodes.isEmpty { Issue.record("\(s.id) has no key code") }
    }
}

// MARK: - Rotation

@Test func aFractionOfADegreeCountsAsAChange() {
    // Rotation was rounded to whole degrees in the signature, so nudging a photo by
    // half a degree looked like no change and the edit was discarded.
    var l = Layer(kind: .bitmap(imageRef: "x.png"))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let flat = l.contentSignature
    l.rotation = 0.5
    #expect(l.contentSignature != flat)
    l.rotation = 1
    let one = l.contentSignature
    l.rotation = 1.25
    #expect(l.contentSignature != one)
}

@Test func rotationTurnsTheArtwork() {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 20),
                                     transform: nil), closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 20)
    l.style.fills = [Fill(paint: .color(.black))]

    let flat = try! #require(Compose.flatten([l]).first?.path).boundingBoxOfPath
    #expect(abs(flat.height - 20) < 0.01)

    l.rotation = 90
    let turned = try! #require(Compose.flatten([l]).first?.path).boundingBoxOfPath
    // A 100×20 bar on its end is 20 wide and 100 tall.
    #expect(abs(turned.width - 20) < 0.5)
    #expect(abs(turned.height - 100) < 0.5)
}

@Test func aSmallRotationTiltsWithoutMovingTheCentre() {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 200, height: 200),
                                     transform: nil), closed: true))
    l.frame = CGRect(x: 100, y: 100, width: 200, height: 200)
    let before = try! #require(Compose.flatten([l]).first?.path).boundingBoxOfPath

    l.rotation = 1                       // the one-degree nudge on a photo
    let after = try! #require(Compose.flatten([l]).first?.path).boundingBoxOfPath
    #expect(abs(after.midX - before.midX) < 0.01)
    #expect(abs(after.midY - before.midY) < 0.01)
    #expect(after.width > before.width)  // a tilted square needs a bigger box
}

@Test func rotatingOneLayerTurnsItInPlace() {
    var page = Page(name: "p")
    var l = Layer(kind: .bitmap(imageRef: "x.png"))
    l.frame = CGRect(x: 100, y: 100, width: 200, height: 200)
    page.layers = [l]
    let centre = CGPoint(x: 200, y: 200)

    page.rotate([l.id], about: centre, by: 1,
                startAngles: [l.id: 0], startFrames: [l.id: l.frame])

    #expect(abs(page.layers[0].rotation - 1) < 0.001)
    // Rotating a single layer about its own centre must not move it.
    #expect(abs(page.layers[0].frame.midX - 200) < 0.001)
    #expect(abs(page.layers[0].frame.midY - 200) < 0.001)
}

@Test func rotatingSeveralLayersSwingsThemAroundTheSharedCentre() {
    var page = Page(name: "p")
    func box(_ x: CGFloat) -> Layer {
        var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                         transform: nil), closed: true))
        l.frame = CGRect(x: x, y: 100, width: 40, height: 40)
        return l
    }
    let a = box(100), b = box(300)
    page.layers = [a, b]
    let centre = CGPoint(x: 220, y: 120)      // midpoint of the two boxes

    page.rotate([a.id, b.id], about: centre, by: 180,
                startAngles: [a.id: 0, b.id: 0],
                startFrames: [a.id: a.frame, b.id: b.frame])

    // Turned half a circle: they swap sides rather than spinning where they stand.
    #expect(abs(page.layers[0].frame.midX - 320) < 0.01)
    #expect(abs(page.layers[1].frame.midX - 120) < 0.01)
    #expect(abs(page.layers[0].rotation - 180) < 0.01)
}

@Test func rotationUsesTheAnglesFromWhenTheDragStarted() {
    var page = Page(name: "p")
    var l = Layer(kind: .bitmap(imageRef: "x.png"))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    l.rotation = 10
    page.layers = [l]
    let start = l.frame

    // Three frames of one gesture. Applying to the live value each time would take it
    // to 10+5+10+15; the whole gesture is one turn from where it began.
    for d in [CGFloat(5), 10, 15] {
        page.rotate([l.id], about: CGPoint(x: 50, y: 50), by: d,
                    startAngles: [l.id: 10], startFrames: [l.id: start])
    }
    #expect(abs(page.layers[0].rotation - 25) < 0.001)
}

// MARK: - Saving

@Test func theCompoundExtensionIsPutBackWhateverGetsTyped() {
    // The save panel highlights "Untitled.sw" and leaves ".png" outside the
    // selection, so typing over it produces "Coin.png".
    #expect(SketchyworksFile.normalisedName("Coin.png") == "Coin.sw.png")
    #expect(SketchyworksFile.normalisedName("Coin") == "Coin.sw.png")
    #expect(SketchyworksFile.normalisedName("Coin.sw") == "Coin.sw.png")
    #expect(SketchyworksFile.normalisedName("Coin.sw.png") == "Coin.sw.png")
    // Dots in the name itself are not an extension.
    #expect(SketchyworksFile.normalisedName("1 Year v2.png") == "1 Year v2.sw.png")
    #expect(SketchyworksFile.normalisedName(".png") == "Untitled.sw.png")
}

@Test func aRenamedDocumentStillHoldsEveryLayer() throws {
    // The question behind the naming: is the document in the NAME or in the bytes?
    // It's in the bytes — the payload is found by scanning for the archive, so a file
    // renamed in Finder still opens with everything in it.
    var page = Page(name: "Page 1")
    page.layers = [maskedGroup(), shadowedGroup()]
    var doc = Document()
    doc.pages = [page]

    let written = try SketchyworksFile.write(document: doc, images: [:])
    let renamed = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("just-a-picture-\(UUID().uuidString).png")
    try written.write(to: renamed)
    defer { try? FileManager.default.removeItem(at: renamed) }

    let (back, _) = try SketchyworksFile.read(url: renamed)
    #expect(back.pages.count == 1)
    #expect(back.pages[0].layers.count == 2)
    guard case .group(let kids) = back.pages[0].layers[0].kind else {
        Issue.record("group lost"); return
    }
    #expect(kids.count == 2)
    #expect(kids[0].hasClippingMask)              // and the mask survived too

    // Still a valid PNG, which is the other half of the bargain.
    let head = try Data(contentsOf: renamed).prefix(8)
    #expect(head.elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
}

// MARK: - Pages

private func threePageSource() -> DocumentSource {
    var doc = Document()
    doc.pages = ["One", "Two", "Three"].map { name in
        var p = Page(name: name)
        var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                         transform: nil), closed: true))
        l.name = "in-\(name)"
        p.layers = [l]
        return p
    }
    return DocumentSource.eager(doc, images: [:])
}

@Test func addingAPageDoesNotShuffleTheOthersContents() {
    // Pages resolve by position in the file. Inserting at the front shifts every later
    // position, so without keeping the two apart a page would show another's artwork.
    let src = threePageSource()
    var made = Page(name: "New")
    made.layers = []
    src.insert(made, at: 0)

    #expect(src.pageCount == 4)
    #expect(src.pages.map(\.name) == ["New", "One", "Two", "Three"])
    // Each page still holds what it held.
    for (i, name) in ["New", "One", "Two", "Three"].enumerated() {
        let page = src.page(at: i)
        #expect(page?.name == name)
        if name != "New" {
            #expect(page?.layers.first?.name == "in-\(name)")
        }
    }
}

@Test func removingAPageKeepsTheRestPointingAtTheirOwnContents() {
    let src = threePageSource()
    let taken = src.remove(at: 1)
    #expect(taken?.name == "Two")
    #expect(src.pages.map(\.name) == ["One", "Three"])
    #expect(src.page(at: 0)?.layers.first?.name == "in-One")
    #expect(src.page(at: 1)?.layers.first?.name == "in-Three")
}

@Test func aRemovedPageCanBePutBackWhereItWas() {
    let src = threePageSource()
    guard let taken = src.remove(at: 1) else { Issue.record("nothing removed"); return }
    src.insert(taken, at: 1)
    #expect(src.pages.map(\.name) == ["One", "Two", "Three"])
    #expect(src.page(at: 1)?.layers.first?.name == "in-Two")
}

@Test func theLastPageCannotBeRemoved() {
    var doc = Document()
    doc.pages = [Page(name: "Only")]
    let src = DocumentSource.eager(doc, images: [:])
    #expect(src.remove(at: 0) == nil)
    #expect(src.pageCount == 1)
}

@Test func renamingAPageChangesBothTheListAndThePage() {
    let src = threePageSource()
    src.rename(at: 1, to: "Renamed")
    #expect(src.pages[1].name == "Renamed")
    #expect(src.page(at: 1)?.name == "Renamed")
    #expect(src.page(at: 1)?.layers.first?.name == "in-Two")   // same page, new name
}

@Test func addedPagesSurviveSaving() throws {
    let src = threePageSource()
    var made = Page(name: "Fresh")
    var l = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 20, height: 20),
                                     transform: nil), closed: true))
    l.name = "disc"
    made.layers = [l]
    src.insert(made, at: 1)

    var doc = Document()
    doc.pages = (0..<src.pageCount).compactMap { src.page(at: $0) }
    let (back, _) = try SketchyworksFile.read(SketchyworksFile.write(document: doc, images: [:]))
    #expect(back.pages.map(\.name) == ["One", "Fresh", "Two", "Three"])
    #expect(back.pages[1].layers.first?.name == "disc")
}

@Test func aRenamedPageComesBackOutOfRemoveWithItsNewName() {
    // Delete-then-undo restored the old name: remove() handed back the cached page,
    // and rename() had only updated the list entry when the page wasn't cached.
    let src = threePageSource()
    var made = Page(name: "Fresh")
    src.insert(made, at: 1)
    src.rename(at: 1, to: "Renamed")
    let taken = src.remove(at: 1)
    #expect(taken?.name == "Renamed")

    // And the same for a page that came from the file and was never touched.
    made = Page(name: "x")
    _ = made
    src.rename(at: 0, to: "First")
    #expect(src.remove(at: 0)?.name == "First")
}

@Test func whatIsHigherInTheListIsDrawnInFront() {
    // The list is drawn top-first and the model is stored bottom-first. Showing the
    // model's order directly put the topmost layer at the BOTTOM of the list, so a
    // layer that looked like it was in front was painted behind.
    var page = Page(name: "p")
    func box(_ name: String) -> Layer {
        var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                         transform: nil), closed: true))
        l.name = name
        l.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        l.style.fills = [Fill(paint: .color(.black))]
        return l
    }
    page.layers = [box("Photo"), box("Ellipse")]      // Ellipse is last = on top

    // Drawn last means drawn in front.
    let painted = Compose.flatten(page.layers).map(\.layer.name)
    #expect(painted == ["Photo", "Ellipse"])

    // And the list, which reverses, shows Ellipse first.
    let listed = page.layers.reversed().map(\.name)
    #expect(listed == ["Ellipse", "Photo"])
    #expect(listed.first == painted.last, "the top row must be the front-most layer")
}


@Test func aRowNearTheTopOfTheListIsAHighIndexInTheModel() {
    // The list is drawn top-first and layers are stored bottom-first, so the two run
    // opposite ways. AppKit says "insert before display row N"; the model counts from
    // the other end, and getting this backwards puts a layer behind what it should be
    // in front of.
    #expect(LayerOrder.modelIndex(displayIndex: 0, childCount: 3) == 3)   // top of the list
    #expect(LayerOrder.modelIndex(displayIndex: 3, childCount: 3) == 0)   // bottom
    #expect(LayerOrder.modelIndex(displayIndex: 1, childCount: 3) == 2)
    // Out of range can't produce an index the model would reject.
    #expect(LayerOrder.modelIndex(displayIndex: 99, childCount: 3) == 0)
    #expect(LayerOrder.modelIndex(displayIndex: -5, childCount: 3) == 3)
}

@Test func reorderingPagesCarriesTheirContentsAlong() {
    // Pages resolve by position in the file, so a reorder has to move the mapping as
    // well as the list — otherwise a page keeps its name and shows another's artwork.
    let src = threePageSource()
    #expect(src.move(from: 2, to: 0))
    #expect(src.pages.map(\.name) == ["Three", "One", "Two"])
    for (i, name) in ["Three", "One", "Two"].enumerated() {
        #expect(src.page(at: i)?.name == name)
        #expect(src.page(at: i)?.layers.first?.name == "in-\(name)")
    }
}

@Test func reorderingPagesBackAndForthIsAWashout() {
    let src = threePageSource()
    src.move(from: 0, to: 2)
    src.move(from: 2, to: 0)
    #expect(src.pages.map(\.name) == ["One", "Two", "Three"])
    #expect(src.page(at: 1)?.layers.first?.name == "in-Two")
}

@Test func movingAPageNowhereChangesNothing() {
    let src = threePageSource()
    #expect(!src.move(from: 1, to: 1))
    #expect(!src.move(from: 9, to: 0))
    #expect(src.pages.map(\.name) == ["One", "Two", "Three"])
}

// MARK: - How far the canvas runs

@Test func theCanvasExtendsWellPastTheArtwork() {
    // A 500-point artboard sat on a document about 550 across — there was nowhere to
    // scroll to, which is what pinned it to the middle of the window.
    let margin = CanvasExtent.margin(for: CGSize(width: 500, height: 500))
    #expect(margin >= 4000)
    #expect(500 + margin * 2 > 8000)     // room in every direction
}

@Test func aBigPageGetsProportionallyMoreRoom() {
    // The coin pages run to 15,000 points. A fixed margin would feel generous around
    // an icon and cramped around those.
    #expect(CanvasExtent.margin(for: CGSize(width: 15_000, height: 5_000)) == 30_000)
}

@Test func theCanvasMarginNeverCollapsesForATinyPage() {
    #expect(CanvasExtent.margin(for: CGSize(width: 10, height: 10)) == 4000)
    #expect(CanvasExtent.margin(for: .zero) == 4000)
}

// MARK: - Minimap

@Test func theMinimapAppearsOnlyWhenTheArtworkIsOffScreen() {
    let art = CGRect(x: 0, y: 0, width: 500, height: 500)
    // Looking at it, or overlapping it: nothing needed.
    #expect(!Minimap.isNeeded(content: art, visible: CGRect(x: 0, y: 0, width: 800, height: 600)))
    #expect(!Minimap.isNeeded(content: art, visible: CGRect(x: 400, y: 400, width: 800, height: 600)))
    // Panned away entirely: needed.
    #expect(Minimap.isNeeded(content: art, visible: CGRect(x: 3000, y: 0, width: 800, height: 600)))
    // An empty page has nothing to point at.
    #expect(!Minimap.isNeeded(content: .zero, visible: CGRect(x: 3000, y: 0, width: 800, height: 600)))
}

@Test func theMinimapShowsBothTheArtworkAndWhereYouAre() {
    let art = CGRect(x: 0, y: 0, width: 500, height: 500)
    let away = CGRect(x: 4000, y: 200, width: 800, height: 600)
    let card = CGSize(width: 160, height: 120)
    let t = Minimap.transform(content: art, visible: away, into: card)

    // Both land inside the card, or it can't tell you which way to go back.
    for r in [art, away] {
        let mapped = r.applying(t)
        #expect(mapped.minX >= -0.01)
        #expect(mapped.minY >= -0.01)
        #expect(mapped.maxX <= card.width + 0.01)
        #expect(mapped.maxY <= card.height + 0.01)
    }
    // And they keep their relationship: the viewport is to the right of the artwork.
    #expect(art.applying(t).midX < away.applying(t).midX)
}

@Test func theMinimapKeepsTheArtworkSquareRatherThanStretchingIt() {
    let art = CGRect(x: 0, y: 0, width: 400, height: 400)
    let away = CGRect(x: 2000, y: 0, width: 400, height: 400)
    let t = Minimap.transform(content: art, visible: away, into: CGSize(width: 160, height: 120))
    let mapped = art.applying(t)
    #expect(abs(mapped.width - mapped.height) < 0.01)
}

// MARK: - Boolean operations

private func twoOverlappingSquares() -> (Page, a: String, b: String) {
    func square(_ x: CGFloat, _ name: String) -> Layer {
        var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                         transform: nil), closed: true))
        l.name = name
        l.frame = CGRect(x: x, y: 0, width: 100, height: 100)
        l.style.fills = [Fill(paint: .color(.black))]
        return l
    }
    let a = square(0, "A"), b = square(50, "B")     // overlap from 50 to 100
    var page = Page(name: "p")
    page.layers = [a, b]
    return (page, a.id, b.id)
}

private func drawnBounds(_ page: Page) -> CGRect {
    Compose.flatten(page.layers).compactMap(\.path).reduce(CGRect.null) {
        $0.union($1.boundingBoxOfPath)
    }
}

@Test func unionDrawsBothShapesAsOne() {
    var (page, a, b) = twoOverlappingSquares()
    let made = page.combine([a, b], op: .union)
    #expect(made != nil)
    #expect(page.layers.count == 1)
    // 0 to 150 across, because the two overlap in the middle.
    let box = drawnBounds(page)
    #expect(abs(box.minX - 0) < 0.5)
    #expect(abs(box.maxX - 150) < 0.5)
}

@Test func subtractTakesTheSecondShapeOutOfTheFirst() {
    var (page, a, b) = twoOverlappingSquares()
    page.combine([a, b], op: .subtract)
    // A minus B leaves 0...50.
    let box = drawnBounds(page)
    #expect(abs(box.minX - 0) < 0.5)
    #expect(abs(box.maxX - 50) < 0.5)
}

@Test func subtractUsesLayerOrderNotTheOrderYouClickedIn() {
    // The bottom layer is the base, as in Sketch and Figma. Selecting them the other
    // way round changes nothing — which is the point: the result is a property of the
    // document, not of how you happened to click.
    var (first, a, b) = twoOverlappingSquares()
    first.combine([a, b], op: .subtract)
    var (second, c, d) = twoOverlappingSquares()
    second.combine([d, c], op: .subtract)
    #expect(abs(drawnBounds(first).maxX - drawnBounds(second).maxX) < 0.5)
    #expect(abs(drawnBounds(first).maxX - 50) < 0.5)      // A minus B: the left half

    // Reordering the layers is what flips it.
    var (third, e, f) = twoOverlappingSquares()
    third.layers.swapAt(0, 1)                             // B underneath now
    third.combine([e, f], op: .subtract)
    #expect(abs(drawnBounds(third).maxX - 150) < 0.5)     // B minus A: the right half
}

@Test func intersectKeepsOnlyTheOverlap() {
    var (page, a, b) = twoOverlappingSquares()
    page.combine([a, b], op: .intersect)
    let box = drawnBounds(page)
    #expect(abs(box.minX - 50) < 0.5)
    #expect(abs(box.maxX - 100) < 0.5)
}

@Test func differenceRemovesTheOverlap() {
    var (page, a, b) = twoOverlappingSquares()
    page.combine([a, b], op: .difference)
    let box = drawnBounds(page)
    // Outer extent unchanged; the middle is gone, which the area check catches.
    #expect(abs(box.minX - 0) < 0.5)
    #expect(abs(box.maxX - 150) < 0.5)
    let path = Compose.flatten(page.layers).first?.path
    #expect(path?.contains(CGPoint(x: 75, y: 50)) == false, "the overlap should be empty")
    #expect(path?.contains(CGPoint(x: 25, y: 50)) == true)
}

@Test func combiningKeepsTheShapesWhereTheyWere() {
    var (page, a, b) = twoOverlappingSquares()
    let before = drawnBounds(page)
    page.combine([a, b], op: .union)
    let after = drawnBounds(page)
    // Children are stored relative to the combined shape; getting that wrong moves
    // the artwork by the new frame's origin.
    #expect(abs(after.minX - before.minX) < 0.5)
    #expect(abs(after.minY - before.minY) < 0.5)
}

@Test func combiningIsUndoneByUngrouping() {
    // Non-destructive: the originals are still in there.
    var (page, a, b) = twoOverlappingSquares()
    guard let made = page.combine([a, b], op: .subtract) else { Issue.record("no shape"); return }
    guard case .shapeGroup(let kids, _) = page.layer(made)!.kind else {
        Issue.record("not a combined shape"); return
    }
    #expect(kids.count == 2)
    #expect(kids[0].booleanOp == .none)        // the base
    #expect(kids[1].booleanOp == .subtract)
    #expect(kids.map(\.name) == ["A", "B"])
}

@Test func aSingleLayerCannotBeCombined() {
    var (page, a, _) = twoOverlappingSquares()
    let single = page.combine([a], op: .union)
    #expect(single == nil)
    #expect(page.layers.count == 2)
}

@Test func layersInDifferentContainersCannotBeCombined() {
    // No sensible frame for a shape spanning two artboards.
    var page = Page(name: "p")
    var loose = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                         transform: nil), closed: true))
    loose.name = "Loose"
    var inside = loose
    inside.name = "Inside"
    var art = Layer(kind: .group([inside]))
    art.isArtboard = true
    art.frame = CGRect(x: 200, y: 0, width: 300, height: 300)
    page.layers = [loose, art]
    let across = page.combine([loose.id, inside.id], op: .union)
    #expect(across == nil)
}

@Test func flatteningReplacesTheGroupWithOnePath() {
    var (page, a, b) = twoOverlappingSquares()
    guard let made = page.combine([a, b], op: .union) else { Issue.record("no shape"); return }
    let before = drawnBounds(page)

    let flattened = page.flattenShape(made)
    #expect(flattened)
    guard case .path = page.layer(made)!.kind else {
        Issue.record("should be an ordinary path now"); return
    }
    // Same drawing, fewer parts.
    let after = drawnBounds(page)
    #expect(abs(after.width - before.width) < 0.5)
    #expect(abs(after.height - before.height) < 0.5)
}

@Test func changingTheOperationChangesTheShape() {
    var (page, a, b) = twoOverlappingSquares()
    guard let made = page.combine([a, b], op: .union) else { Issue.record("no shape"); return }
    #expect(abs(drawnBounds(page).maxX - 150) < 0.5)

    guard case .shapeGroup(let kids, _) = page.layer(made)!.kind else { return }
    page.setBooleanOp(kids[1].id, to: .intersect)
    #expect(abs(drawnBounds(page).minX - 50) < 0.5)
}

@Test func chatCanCombineShapes() {
    var (page, _, _) = twoOverlappingSquares()
    let cmds = DocumentCommand.decodeList(Data(#"[{"op":"subtract","type":"path"}]"#.utf8))
    #expect(cmds.count == 1)
    let run = page.run(cmds)
    #expect(page.layers.count == 1)
    #expect(run.report.contains("2 shapes into one"))
    #expect(abs(drawnBounds(page).maxX - 50) < 0.5)
}

@Test func combiningOneShapeSaysSoRatherThanFailingQuietly() {
    var page = Page(name: "p")
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                     transform: nil), closed: true))
    l.name = "only"
    page.layers = [l]
    let run = page.run(DocumentCommand.decodeList(Data(#"[{"op":"union","name":"only"}]"#.utf8)))
    #expect(run.report.contains("at least two"))
    #expect(page.layers.count == 1)
}

@Test func chatCanFlattenACombinedShape() {
    var (page, a, b) = twoOverlappingSquares()
    page.combine([a, b], op: .union)
    _ = page.run(DocumentCommand.decodeList(Data(#"[{"op":"flatten","type":"shapeGroup"}]"#.utf8)))
    guard case .path = page.layers[0].kind else {
        Issue.record("should be a plain path now"); return
    }
}

// MARK: - Erasing a bitmap

/// Reads the mask's grey value at a point in layer coordinates. White keeps, black
/// erases, so this answers "was this bit rubbed out?".
private func maskValue(_ strokes: [EraseStroke], size: CGSize, at p: CGPoint) -> Int? {
    guard let img = EraseMask.image(strokes: strokes, size: size, scale: 1),
          let data = img.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else { return nil }
    let x = Int(p.x), y = Int(size.height - p.y)      // the mask is built y-up
    guard x >= 0, y >= 0, x < img.width, y < img.height else { return nil }
    return Int(bytes[y * img.bytesPerRow + x])
}

@Test func aHardStrokeRemovesWhatItCoversAndNothingElse() {
    let size = CGSize(width: 200, height: 200)
    let stroke = EraseStroke(points: [CGPoint(x: 100, y: 100)], radius: 30, softness: 0)

    #expect(maskValue([stroke], size: size, at: CGPoint(x: 100, y: 100)) == 0)   // erased
    #expect(maskValue([stroke], size: size, at: CGPoint(x: 20, y: 20)) == 255)   // untouched
}

@Test func softnessFadesTheEdgeRatherThanCuttingIt() {
    let size = CGSize(width: 200, height: 200)
    let soft = EraseStroke(points: [CGPoint(x: 100, y: 100)], radius: 40, softness: 1)

    let centre = maskValue([soft], size: size, at: CGPoint(x: 100, y: 100)) ?? -1
    let middle = maskValue([soft], size: size, at: CGPoint(x: 122, y: 100)) ?? -1
    let outside = maskValue([soft], size: size, at: CGPoint(x: 145, y: 100)) ?? -1

    // Effectively gone at the centre. Not exactly 0: at full softness the fade starts
    // from the middle, so the very centre pixel carries a little of the gradient.
    #expect(centre < 10)
    #expect(middle > 20 && middle < 235)       // and part-way out, part-way gone
    #expect(outside == 255)                    // beyond the brush, untouched
}

@Test func aHardBrushHasNoGradientAtAll() {
    let size = CGSize(width: 200, height: 200)
    let hard = EraseStroke(points: [CGPoint(x: 100, y: 100)], radius: 40, softness: 0)
    // Just inside the edge is still fully erased, unlike the soft brush.
    #expect(maskValue([hard], size: size, at: CGPoint(x: 135, y: 100)) == 0)
}

@Test func aDraggedStrokeErasesTheWholeLineNotJustTheEnds() {
    // Stamped along the path: a gap in the middle would mean the dab spacing is wrong.
    let size = CGSize(width: 300, height: 100)
    let drag = EraseStroke(points: [CGPoint(x: 30, y: 50), CGPoint(x: 270, y: 50)],
                           radius: 15, softness: 0)
    for x in stride(from: 35.0, through: 265.0, by: 10.0) {
        #expect(maskValue([drag], size: size, at: CGPoint(x: x, y: 50)) == 0,
                "gap at x=\(x)")
    }
}

@Test func erasingIsStoredNotBurntIntoThePicture() throws {
    // The same photo is used on several coins; an erase that edited the pixels would
    // be a second copy of it.
    var photo = Layer(kind: .bitmap(imageRef: "coin.png"))
    photo.name = "Photo"
    photo.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    photo.erased = [EraseStroke(points: [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 150)],
                                radius: 20, softness: 0.6)]

    var page = Page(name: "Page 1")
    page.layers = [photo]
    var doc = Document()
    doc.pages = [page]

    let (back, _) = try SketchyworksFile.read(SketchyworksFile.write(document: doc, images: [:]))
    let restored = back.pages[0].layers[0]
    #expect(restored.erased.count == 1)
    #expect(restored.erased[0].points.count == 2)
    #expect(restored.erased[0].radius == 20)
    #expect(abs(restored.erased[0].softness - 0.6) < 0.001)
    // Still a plain bitmap reference: the image itself was never rewritten.
    guard case .bitmap(let ref) = restored.kind else { Issue.record("not a bitmap"); return }
    #expect(ref == "coin.png")
}

@Test func anEraseCountsAsAChange() {
    var l = Layer(kind: .bitmap(imageRef: "x.png"))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let clean = l.contentSignature
    l.erased = [EraseStroke(points: [CGPoint(x: 10, y: 10)], radius: 5)]
    #expect(l.contentSignature != clean)

    let one = l.contentSignature
    l.erased[0].radius = 25
    #expect(l.contentSignature != one, "changing the brush size is a change too")
}

@Test func anEmptyStrokeListCostsNothing() {
    #expect(EraseMask.image(strokes: [], size: CGSize(width: 100, height: 100)) == nil)
}

// MARK: - Text on a path

@Test func textFollowsAnArbitraryPath() {
    // A quarter circle: text laid along it must curve, not run straight.
    let arc = CGMutablePath()
    arc.addArc(center: CGPoint(x: 0, y: 200), radius: 200,
               startAngle: -.pi / 2, endAngle: 0, clockwise: false)

    var run = TextRun()
    run.string = "CURVING ALONG"
    run.fontName = "Helvetica-Bold"
    run.fontSize = 24
    run.onPath = arc

    let box = try! #require(TextOutline.path(run, in: CGRect(x: 0, y: 0, width: 400, height: 400)))
        .boundingBoxOfPath
    // Straight text this long is ~180 wide and 24 tall; bent round a quarter circle
    // it must be tall as well as wide.
    #expect(box.height > 80)
    #expect(box.width > 80)
}

@Test func textOnAPathBeatsAnArcWhenBothAreSet() {
    // onPath is the more specific instruction: an imported layer can carry a path,
    // and a stale arc must not win.
    let line = CGMutablePath()
    line.move(to: .zero)
    line.addLine(to: CGPoint(x: 400, y: 0))

    var run = TextRun()
    run.string = "STRAIGHT"
    run.fontName = "Helvetica"
    run.fontSize = 20
    run.arc = TextArc(radius: 100)
    run.onPath = line

    let box = try! #require(TextOutline.path(run, in: CGRect(x: 0, y: 0, width: 400, height: 400)))
        .boundingBoxOfPath
    #expect(box.height < 30, "should follow the straight path, not the arc")
}

@Test func textOnPathSurvivesSavingAndReopening() throws {
    let arc = CGMutablePath()
    arc.addArc(center: CGPoint(x: 200, y: 200), radius: 150,
               startAngle: .pi, endAngle: 2 * .pi, clockwise: false)

    var run = TextRun()
    run.string = "ROUND THE TOP"
    run.fontName = "Helvetica"
    run.fontSize = 22
    run.onPath = arc

    var l = Layer(kind: .text(run))
    l.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
    var page = Page(name: "Page 1")
    page.layers = [l]
    var doc = Document()
    doc.pages = [page]

    let (back, _) = try SketchyworksFile.read(SketchyworksFile.write(document: doc, images: [:]))
    guard case .text(let restored) = back.pages[0].layers[0].kind else {
        Issue.record("not text"); return
    }
    let path = try #require(restored.onPath)
    #expect(abs(path.boundingBoxOfPath.width - 300) < 2)
}

@Test func sortByPositionPutsReadingOrderAtTheTopOfTheList() {
    // Four artboards in a 2×2 grid, stored in a scrambled order. The layer list
    // shows front-most (array end) first, so after sorting by position the END
    // of the array must be the top-left board and the START the bottom-right.
    func board(_ name: String, _ x: CGFloat, _ y: CGFloat) -> Layer {
        var l = Layer(kind: .group([]))
        l.isArtboard = true
        l.name = name
        l.frame = CGRect(x: x, y: y, width: 100, height: 100)
        return l
    }
    var page = Page(name: "P")
    page.layers = [board("bottom-left", 0, 200), board("top-right", 200, 0),
                   board("bottom-right", 200, 200), board("top-left", 0, 0)]

    let run = page.run([.sort(LayerQuery(), by: "position")])
    #expect(run.report.contains("4 layers reordered"))
    #expect(page.layers.map(\.name) ==
            ["bottom-right", "bottom-left", "top-right", "top-left"])
}

@Test func sortByNameAlphabetisesTheListTopDown() {
    func layer(_ name: String) -> Layer {
        var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
        l.name = name
        return l
    }
    var page = Page(name: "P")
    page.layers = [layer("banana"), layer("cherry"), layer("apple")]
    page.run([.sort(LayerQuery(), by: "name")])
    // List reads apple, banana, cherry from the top — array end is the top.
    #expect(page.layers.map(\.name) == ["cherry", "banana", "apple"])
}

@Test func autoShapesKeepTheirRecipe() throws {
    var page = Page(name: "P")
    var spec = AddSpec()
    spec.kind = "star"; spec.sides = 5
    let id = try #require(page.add(spec) as String?)
    let star = try #require(page.layer(id))
    #expect(star.autoShape?.kind == .star)
    #expect(star.pointCount == 10)                 // five spikes = ten vertices

    // Re-cook to seven points and the path follows the recipe.
    var l = star
    l.autoShape?.sides = 7
    l.regenerateAutoShape()
    #expect(l.pointCount == 14)

    var pspec = AddSpec()
    pspec.kind = "polygon"; pspec.sides = 6
    let hexID = try #require(page.add(pspec) as String?)
    #expect(page.layer(hexID)?.pointCount == 6)
}

@Test func autoShapeSurvivesTheDocumentFormat() throws {
    var page = Page(name: "P")
    var spec = AddSpec()
    spec.kind = "star"; spec.sides = 8; spec.innerRatio = 0.3
    _ = page.add(spec)
    var doc = Document()
    doc.pages = [page]
    let data = try SketchyworksFile.write(document: doc, images: [:])
    let back = try SketchyworksFile.read(data)
    let star = try #require(back.document.pages.first?.layers.first)
    #expect(star.autoShape == AutoShape(kind: .star, sides: 8, innerRatio: 0.3))
}

@Test func bitmapAdjustmentsAndCropSurviveTheFormat() throws {
    var l = Layer(kind: .bitmap(imageRef: "photo.png"))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 80)
    l.brightness = 0.2
    l.contrast = 1.3
    l.saturation = 0.7
    l.cropRect = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
    l.erased = [EraseStroke(rect: CGRect(x: 5, y: 5, width: 20, height: 10))]
    var page = Page(name: "P")
    page.layers = [l]
    var doc = Document()
    doc.pages = [page]
    let data = try SketchyworksFile.write(document: doc, images: ["photo.png": Data([0x89, 0x50])])
    let back = try SketchyworksFile.read(data).document.pages[0].layers[0]
    #expect(back.brightness == 0.2)
    #expect(back.contrast == 1.3)
    #expect(back.saturation == 0.7)
    #expect(back.cropRect == CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
    #expect(back.erased.first?.rect == CGRect(x: 5, y: 5, width: 20, height: 10))
}

@Test func rectEraseCutsAHoleInTheMask() throws {
    let strokes = [EraseStroke(rect: CGRect(x: 10, y: 10, width: 30, height: 20))]
    let mask = try #require(EraseMask.image(strokes: strokes, size: CGSize(width: 100, height: 100)))
    // Sample the mask: inside the rect should be dark (erased), outside light.
    func luminance(_ x: Int, _ y: Int) -> UInt8 {
        let data = mask.dataProvider!.data! as Data
        let bpr = mask.bytesPerRow
        return data[y * bpr + x]
    }
    // Mask is drawn at 2x scale.
    #expect(luminance(40, 40) < 32)     // inside (20,20)
    #expect(luminance(160, 160) > 224)  // outside (80,80)
}

@Test func brightnessActuallyBrightensTheRender() throws {
    // A real PNG, mid-grey.
    let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let png = try #require(Renderer.png(ctx.makeImage()!))

    var l = Layer(kind: .bitmap(imageRef: "grey"))
    l.frame = CGRect(x: 0, y: 0, width: 8, height: 8)
    var page = Page(name: "P")
    page.layers = [l]

    func centrePixel() -> UInt8 {
        let img = Renderer(images: ["grey": png]).render(page: page, maxDimension: 8)!
        let data = img.dataProvider!.data! as Data
        return data[(img.height / 2) * img.bytesPerRow + (img.width / 2) * 4]
    }
    let before = centrePixel()
    page.layers[0].brightness = 0.4
    let after = centrePixel()
    #expect(after > before + 40)
}

@Test func aDeletedImageDoesNotRideAlongInTheArchive() throws {
    var photo = Layer(kind: .bitmap(imageRef: "kept.png"))
    photo.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    var page = Page(name: "p")
    page.layers = [photo]
    var doc = Document()
    doc.pages = [page]

    // The store still holds bytes for an image whose layer was deleted — undo
    // needs them back — but the file must only carry what the artwork references.
    let images = ["kept.png": Data([1]), "orphan.png": Data([2])]
    let back = try Zip.read(try SketchyworksFile.write(document: doc, images: images))
    #expect(back["assets/kept.png"] != nil)
    #expect(back["assets/orphan.png"] == nil)
}
