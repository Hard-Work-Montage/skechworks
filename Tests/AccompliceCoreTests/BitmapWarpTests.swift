import Testing
import CoreGraphics
import Foundation
@testable import AccompliceCore

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
    var l = Layer(kind: .bitmap(imageRef: "w.png"))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    l.warpCorners = [CGPoint(x: 0, y: 0), CGPoint(x: 0.8, y: 0.15),
                     CGPoint(x: 0.8, y: 0.85), CGPoint(x: 0, y: 1)]
    var page = Page(name: "p")
    page.layers = [l]
    var doc = Document()
    doc.pages = [page]

    let data = try AcmplcFile.write(document: doc, images: ["w.png": whitePNG(width: 4, height: 4)])
    let (readDoc, _) = try AcmplcFile.read(data)
    let back = try #require(readDoc.pages.first?.layers.first?.warpCorners)
    #expect(back.count == 4)
    #expect(abs(back[1].x - 0.8) < 0.0001 && abs(back[1].y - 0.15) < 0.0001)
}

@Test func theDistortCommandSetsAndClearsTheWarp() throws {
    var l = Layer(kind: .bitmap(imageRef: "w.png"))
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

    var l = Layer(kind: .bitmap(imageRef: "w.png"))
    l.frame = CGRect(x: 0, y: 0, width: 128, height: 72)
    l.erased = [EraseStroke(points: [CGPoint(x: 64, y: 9)], radius: 12, softness: 0)]
    l.warpCorners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                     CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    var page = Page(name: "p")
    page.layers = [l]

    let img = Renderer(images: ["w.png": png],
                       background: Color(r: 1, g: 0, b: 0, a: 1)).render(page: page, maxDimension: 128)!
    let data = img.dataProvider!.data! as Data
    func green(_ x: Int, _ y: Int) -> UInt8 { data[y * img.bytesPerRow + x * 4 + 1] }
    let x = img.width / 2
    #expect(green(x, img.height * 9 / 72) < 60, "the hole is where the stroke was")
    #expect(green(x, img.height * 63 / 72) > 200, "the mirrored spot is untouched")
}
