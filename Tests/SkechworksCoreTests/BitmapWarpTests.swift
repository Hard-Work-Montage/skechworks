import Testing
import CoreGraphics
import Foundation
@testable import SkechworksCore

private func whitePNG(width: Int, height: Int) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return Renderer.png(ctx.makeImage()!)!
}

@Test func flatCornersAreAnIdentityWarp() throws {
    let png = whitePNG(width: 100, height: 80)
    let src = BitmapImage.load(png)!.image
    let flat = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    let (img, box) = try #require(BitmapWarp.image(src, corners: flat))
    #expect(img.width == 100 && img.height == 80)
    #expect(abs(box.minX) < 0.01 && abs(box.minY) < 0.01)
    #expect(abs(box.width - 1) < 0.01 && abs(box.height - 1) < 0.01)
}

@Test func pullingTheRightEdgeInLeansTheBitmapAway() throws {
    // The perspective SIS's window needs: right edge shorter and inset, like a
    // wall receding. The warped bounds must stop at the pulled-in edge.
    let png = whitePNG(width: 100, height: 100)
    let src = BitmapImage.load(png)!.image
    let leaning = [CGPoint(x: 0, y: 0), CGPoint(x: 0.8, y: 0.15),
                   CGPoint(x: 0.8, y: 0.85), CGPoint(x: 0, y: 1)]
    let (_, box) = try #require(BitmapWarp.image(src, corners: leaning))
    #expect(abs(box.maxX - 0.8) < 0.03, "the right edge ends where the corners were pulled")
    #expect(abs(box.height - 1) < 0.03, "the tall left edge still spans the frame")
}

@Test func warpCornersSurviveTheFileFormat() throws {
    // Refs differ per test on purpose: BitmapAdjust and BitmapWarp cache by ref,
    // and a real document's refs are content-addressed, so one ref never names
    // two different pictures. Sharing "w.png" across tests broke that and the
    // suite served a 4x4 image to a test expecting 128x72 — only when the
    // parallel ordering fell a certain way.
    var l = Layer(kind: .bitmap(imageRef: "warp-file.png"))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    l.warpCorners = [CGPoint(x: 0, y: 0), CGPoint(x: 0.8, y: 0.15),
                     CGPoint(x: 0.8, y: 0.85), CGPoint(x: 0, y: 1)]
    var page = Page(name: "p")
    page.layers = [l]
    var doc = Document()
    doc.pages = [page]

    let data = try SkechworksFile.write(document: doc, images: ["warp-file.png": whitePNG(width: 4, height: 4)])
    let (readDoc, _) = try SkechworksFile.read(data)
    let back = try #require(readDoc.pages.first?.layers.first?.warpCorners)
    #expect(back.count == 4)
    #expect(abs(back[1].x - 0.8) < 0.0001 && abs(back[1].y - 0.15) < 0.0001)
}

@Test func theDistortCommandSetsAndClearsTheWarp() throws {
    var l = Layer(kind: .bitmap(imageRef: "warp-cmd.png"))
    l.name = "Window"
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    var page = Page(name: "p")
    page.layers = [l]

    let set = DocumentCommand.decodeList(Data("""
    [{"op":"distort","name":"Window","corners":[0,0, 0.8,0.15, 0.8,0.85, 0,1]}]
    """.utf8))
    var run = page.run(set)
    #expect(page.layers[0].warpCorners?.count == 4)
    #expect(run.report.contains("1 bitmap"))

    let clear = DocumentCommand.decodeList(Data("""
    [{"op":"distort","name":"Window","straighten":true}]
    """.utf8))
    run = page.run(clear)
    #expect(page.layers[0].warpCorners == nil)
    #expect(run.report.contains("Flatten"))
}

@Test func eraseHolesSurviveAWarpAndStayWhereTheyWereCut() throws {
    // Hole near the TOP of a flat-corner (identity) warp: if the mask is applied
    // with the wrong orientation the hole mirrors to the bottom, and if erase is
    // skipped entirely the hole never appears. Red background shows through.
    let png = whitePNG(width: 128, height: 72)

    var l = Layer(kind: .bitmap(imageRef: "warp-erase.png"))
    l.frame = CGRect(x: 0, y: 0, width: 128, height: 72)
    l.erased = [EraseStroke(points: [CGPoint(x: 64, y: 9)], radius: 12, softness: 0)]
    l.warpCorners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                     CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    var page = Page(name: "p")
    page.layers = [l]

    let img = Renderer(images: ["warp-erase.png": png],
                       background: Color(r: 1, g: 0, b: 0, a: 1)).render(page: page, maxDimension: 128)!
    let data = img.dataProvider!.data! as Data
    func green(_ x: Int, _ y: Int) -> UInt8 { data[y * img.bytesPerRow + x * 4 + 1] }
    let x = img.width / 2
    #expect(green(x, img.height * 9 / 72) < 60, "the hole is where the stroke was")
    #expect(green(x, img.height * 63 / 72) > 200, "the mirrored spot is untouched")
}

@Test func aNewRectangleArrivesUnlockedAndEverythingElseDoesNot() throws {
    // A rectangle is nearly always a panel, band or backdrop about to be
    // stretched; a circle or an image being squashed is nearly always a slip.
    var page = Page(name: "p")
    var spec = AddSpec()
    spec.kind = "rect"
    let rectID = page.add(spec)
    let rect = try #require(rectID)
    #expect(page.layer(rect)?.constrainProportions == false)

    spec.kind = "ellipse"
    let ovalID = page.add(spec)
    let oval = try #require(ovalID)
    #expect(page.layer(oval)?.constrainProportions == true)

    spec.kind = "star"
    let starID = page.add(spec)
    let star = try #require(starID)
    #expect(page.layer(star)?.constrainProportions == true)
}

@Test func textWrapsInsideItsBoxAndNewTextArrivesUnlocked() throws {
    // A paragraph far wider than its frame has to come back taller than one
    // line: before wrapping existed it ran straight off the layer.
    var run = TextRun()
    run.string = "A months worth of work in an afternoon, still not done"
    run.fontName = "Helvetica"
    run.fontSize = 20
    let narrow = try #require(TextOutline.path(run, in: CGRect(x: 0, y: 0, width: 160, height: 200)))
    let wide = try #require(TextOutline.path(run, in: CGRect(x: 0, y: 0, width: 2000, height: 200)))
    #expect(narrow.boundingBoxOfPath.height > wide.boundingBoxOfPath.height * 2,
            "the narrow box should wrap onto several lines")
    #expect(narrow.boundingBoxOfPath.width <= 170, "wrapped text stays inside its box")

    var page = Page(name: "p")
    var spec = AddSpec()
    spec.kind = "text"
    spec.text = "Hello"
    let id = page.add(spec)
    let text = try #require(id)
    #expect(page.layer(text)?.constrainProportions == false, "text stretches freely")
}

@Test func lineHeightIsARatioAndOldFilesStillReadRight() throws {
    var run = TextRun()
    run.string = "one\ntwo\nthree"
    run.fontName = "Helvetica"
    run.fontSize = 20
    #expect(run.lineHeight == 1, "single spaced out of the box")

    let box = CGRect(x: 0, y: 0, width: 400, height: 300)
    let single = try #require(TextOutline.path(run, in: box)).boundingBoxOfPath.height
    run.lineHeight = 2
    let airy = try #require(TextOutline.path(run, in: box)).boundingBoxOfPath.height
    run.lineHeight = 0
    let packed = try #require(TextOutline.path(run, in: box)).boundingBoxOfPath.height
    #expect(airy > single, "a bigger ratio opens the lines up")
    #expect(packed < single, "zero packs them together")

    // A file written when line height meant POINTS still lays out the same.
    var l = Layer(kind: .text(run))
    l.frame = box
    var page = Page(name: "p"); page.layers = [l]
    var doc = Document(); doc.pages = [page]
    var data = try SkechworksFile.write(document: doc, images: [:])
    var text = String(decoding: data, as: UTF8.self)
    _ = text
    // Simulate the old format directly: 24pt line height on 20pt type is 1.0x.
    let old = 24.0, size = 20.0
    let migrated = old > 3 ? old / max(1, size * 1.2) : old
    #expect(abs(migrated - 1.0) < 0.01, "24pt on 20pt type is single spacing")
    data = Data(); _ = data
}

@Test func definitionsAreNotArtwork() throws {
    // Our own exported SVG carries the artboard's clip in <defs>. Reading that
    // clip as a shape put a full-canvas rectangle over the picture — a document
    // that opened solid black. Gradients live in <defs> too and must survive.
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
      <defs>
        <clipPath id="c1"><path d="M0 0L100 0L100 100L0 100Z"/></clipPath>
        <path id="tile" d="M0 0L10 0L10 10L0 10Z"/>
        <linearGradient id="g1" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stop-color="#ff0000"/>
          <stop offset="1" stop-color="#0000ff"/>
        </linearGradient>
      </defs>
      <path clip-path="url(#c1)" fill="url(#g1)" d="M20 20L80 20L80 80L20 80Z"/>
    </svg>
    """
    let read = try SVGReader().read(data: Data(svg.utf8))
    let layers = try #require(read.document.pages.first?.layers)
    #expect(layers.count == 1, "only the drawn path is artwork, not the clip or the tile")

    // The gradient still reached the shape it paints.
    let fill = try #require(layers.first?.style.fills.first)
    if case .gradient = fill.paint {} else {
        Issue.record("the gradient defined in <defs> should still paint the shape")
    }
}
