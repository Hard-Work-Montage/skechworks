import Testing
import CoreGraphics
import Foundation
@testable import SkechworksCore

private let red = Color(r: 1, g: 0, b: 0, a: 1)

private func line(_ y: CGFloat, paint: Color? = nil, radius: CGFloat = 8) -> EraseStroke {
    EraseStroke(points: [CGPoint(x: 10, y: y), CGPoint(x: 110, y: y)], radius: radius, softness: 0, paint: paint)
}

private func whitePNG(width: Int, height: Int) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return Renderer.png(ctx.makeImage()!)!
}

/// A white picture 120 by 80 on a blue page, with `strokes` on it.
private func rendered(_ strokes: [EraseStroke], warped: Bool = false, opacity: CGFloat = 1) throws -> (Int, Int) -> (UInt8, UInt8, UInt8) {
    var l = Layer(kind: .bitmap(imageRef: "brush.png"))
    l.frame = CGRect(x: 0, y: 0, width: 120, height: 80)
    l.erased = strokes
    l.style.opacity = opacity
    if warped {
        l.warpCorners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    }
    var page = Page(name: "p")
    page.layers = [l]
    let img = try #require(Renderer(images: ["brush.png": whitePNG(width: 120, height: 80)],
                                    background: Color(r: 0, g: 0, b: 1, a: 1)).render(page: page, maxDimension: 120))
    let data = img.dataProvider!.data! as Data
    return { x, y in
        let i = (y * img.height / 80) * img.bytesPerRow + (x * img.width / 120) * 4
        return (data[i], data[i + 1], data[i + 2])
    }
}

private func isRed(_ p: (UInt8, UInt8, UInt8)) -> Bool { p.0 > 200 && p.1 < 60 && p.2 < 60 }
private func isWhite(_ p: (UInt8, UInt8, UInt8)) -> Bool { p.0 > 200 && p.1 > 200 && p.2 > 200 }
private func isBlue(_ p: (UInt8, UInt8, UInt8)) -> Bool { p.0 < 60 && p.1 < 60 && p.2 > 200 }

@Test(arguments: [false, true])
func aBrushStrokeShowsWhereItWasDrawn(warped: Bool) throws {
    // Near the top, so a stroke drawn upside down would land at the bottom.
    let at = try rendered([line(15, paint: red)], warped: warped)
    #expect(isRed(at(60, 15)))
    #expect(isWhite(at(60, 65)), "the mirrored spot is untouched")
}

@Test func anEraseAfterAStrokeTakesThePaintWithIt() throws {
    let at = try rendered([line(40, paint: red), EraseStroke(rect: CGRect(x: 50, y: 0, width: 20, height: 80))])
    #expect(isRed(at(30, 40)))
    #expect(isBlue(at(60, 40)), "paint and picture both gone")
    #expect(isRed(at(90, 40)))
}

@Test func aStrokePaintedIntoAnErasedHoleShows() throws {
    let at = try rendered([EraseStroke(rect: CGRect(x: 50, y: 0, width: 20, height: 80)), line(40, paint: red)])
    #expect(isRed(at(60, 40)))
    #expect(isBlue(at(60, 10)), "the rest of the hole is still a hole")
}

@Test func aSeeThroughStrokeIsOneStrengthAllAlongTheLine() throws {
    // Dabs overlap all along a stroke. Colored a dab at a time, half-strength
    // red would be nearly solid everywhere but the two ends.
    let at = try rendered([line(40, paint: Color(r: 1, g: 0, b: 0, a: 0.5), radius: 10)])
    let mid = at(60, 40), end = at(11, 40)
    #expect(abs(Int(mid.1) - 128) < 12)
    #expect(abs(Int(mid.1) - Int(end.1)) < 6)
}

@Test func aStrokeDrawnAFewPointsAFrameMatchesTheFinishedOne() throws {
    let size = CGSize(width: 161, height: 121)
    let earlier = line(20, paint: Color(r: 0, g: 1, b: 0, a: 1))
    let path = (0..<40).map { CGPoint(x: 10 + CGFloat($0) * 3.3, y: 60 + 30 * sin(CGFloat($0) / 5)) }
    var live: CGImage?
    for n in 1...path.count {
        live = PaintOverlay.image(strokes: [earlier, EraseStroke(points: Array(path[0..<n]), radius: 9, softness: 0.5, paint: red)],
                                  size: size)
    }
    // A different size is a different key, so this one is built from nothing.
    let whole = PaintOverlay.image(strokes: [earlier, EraseStroke(points: path, radius: 9, softness: 0.5, paint: red)],
                                   size: size, scale: 2.0000001)
    let a = try #require(live), b = try #require(whole)
    #expect(a.width == b.width)
    // The hair's difference in scale moves an edge by less than a shade.
    let live8 = [UInt8](a.dataProvider!.data! as Data), whole8 = [UInt8](b.dataProvider!.data! as Data)
    #expect(live8.count == whole8.count)
    #expect(zip(live8, whole8).allSatisfy { abs(Int($0) - Int($1)) <= 3 })
    #expect(live8.contains { $0 > 200 })
}

@Test func erasingAloneMakesNoOverlay() {
    #expect(PaintOverlay.image(strokes: [line(40)], size: CGSize(width: 120, height: 80)) == nil)
    // And paint alone makes no mask, so nothing gets clipped for it.
    #expect(EraseMask.image(strokes: [line(40, paint: red)], size: CGSize(width: 120, height: 81)) == nil)
}

@Test func aBrushStrokeKeepsItsColorThroughSaveAndReopen() throws {
    var photo = Layer(kind: .bitmap(imageRef: "coin.png"))
    photo.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    photo.erased = [line(40, paint: Color(r: 0.2, g: 0.4, b: 0.6, a: 0.5)), line(60)]
    var page = Page(name: "Page 1")
    page.layers = [photo]
    var doc = Document()
    doc.pages = [page]

    let (back, _) = try SkechworksFile.read(SkechworksFile.write(document: doc, images: [:]))
    let strokes = back.pages[0].layers[0].erased
    #expect(strokes.count == 2)
    let c = try #require(strokes[0].paint)
    #expect(abs(c.r - 0.2) < 0.01 && abs(c.g - 0.4) < 0.01 && abs(c.b - 0.6) < 0.01 && abs(c.a - 0.5) < 0.01)
    #expect(strokes[1].paint == nil, "the erase is still an erase")
}
