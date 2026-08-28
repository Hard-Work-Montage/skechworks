import Testing
import CoreGraphics
import Foundation
@testable import SkechworksCore

@Test func anEraseHoleLandsWhereTheStrokeWas() throws {
    // A solid white bitmap over a red background: the hole shows red wherever it
    // lands. The stroke is near the TOP of the layer — if the clip mask is applied
    // with the wrong vertical orientation, the hole appears near the bottom instead,
    // which on asymmetric images reads as "erase does nothing".
    let ctx = CGContext(data: nil, width: 128, height: 72, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 72))
    let white = Renderer.png(ctx.makeImage()!)!

    var l = Layer(kind: .bitmap(imageRef: "w.png"))
    l.frame = CGRect(x: 0, y: 0, width: 128, height: 72)
    l.erased = [EraseStroke(points: [CGPoint(x: 64, y: 9)], radius: 12, softness: 0)]
    var page = Page(name: "p")
    page.layers = [l]

    let img = Renderer(images: ["w.png": white],
                       background: Color(r: 1, g: 0, b: 0, a: 1)).render(page: page, maxDimension: 128)!
    let data = img.dataProvider!.data! as Data
    func green(_ x: Int, _ y: Int) -> UInt8 { data[y * img.bytesPerRow + x * 4 + 1] }
    let x = img.width / 2
    #expect(green(x, img.height * 9 / 72) < 60, "the hole is where the stroke was")
    #expect(green(x, img.height * 63 / 72) > 200, "the mirrored spot is untouched")
}

@Test func resizingABitmapScalesItsEraseStrokes() throws {
    // The hole was cut at one size; resizing the bitmap must carry it along, or
    // the erase lands on art it never touched.
    var l = Layer(kind: .bitmap(imageRef: "w.png"))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    l.erased = [EraseStroke(rect: CGRect(x: 10, y: 20, width: 30, height: 40)),
                EraseStroke(points: [CGPoint(x: 50, y: 50)], radius: 10, softness: 0)]

    l.resize(to: CGSize(width: 200, height: 50))

    let rect = try #require(l.erased[0].rect)
    #expect(rect == CGRect(x: 20, y: 10, width: 60, height: 20))
    #expect(l.erased[1].points[0] == CGPoint(x: 100, y: 25))
    #expect(abs(l.erased[1].radius - 12.5) < 0.001, "radius scales by the average axis")
}
