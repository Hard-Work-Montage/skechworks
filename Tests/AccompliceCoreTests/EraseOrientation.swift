import Testing
import CoreGraphics
import Foundation
@testable import AccompliceCore

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
