import CoreGraphics
import Foundation
import Testing
@testable import SkechworksCore

// What a frame of the canvas costs on a page of photos. Every case here was a
// slow pan on a coin listing page before it was a test.

private func pngOfSolidColor(_ w: Int, _ h: Int) -> Data {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return Renderer.png(ctx.makeImage()!)!
}

@Test func aPictureIsDecodedOnceAndRememberedByRef() {
    BitmapImage.forgetDecodes()
    let data = pngOfSolidColor(300, 200)
    let a = BitmapImage.load(data, ref: "images/a.png")
    let b = BitmapImage.load(data, ref: "images/a.png")
    #expect(a != nil)
    // The same CGImage object, not a fresh decode that happens to match.
    #expect(a?.image === b?.image)

    // Different bytes under the same ref are a different picture.
    let other = pngOfSolidColor(300, 201)
    let c = BitmapImage.load(other, ref: "images/a.png")
    #expect(c?.image !== a?.image)
    #expect(c?.nativeSize.height == 201)
}

@Test func mipsShrinkToTheSizeOnScreenAndNoSmaller() throws {
    let src = try #require(BitmapImage.load(pngOfSolidColor(1024, 768))?.image)

    // Drawn at or above half size: the source itself.
    #expect(BitmapMips.image(src, scale: 1) === src)
    #expect(BitmapMips.image(src, scale: 0.6) === src)

    // A quarter of a device pixel per source pixel: the quarter-size copy,
    // one pixel of picture per pixel of screen.
    let quarter = BitmapMips.image(src, scale: 0.25)
    #expect(quarter.width == 256 && quarter.height == 192)

    // Between levels, the larger one wins, never a copy with less than a
    // pixel of picture per device pixel.
    let between = BitmapMips.image(src, scale: 0.3)
    #expect(between.width == 512)

    // Asked again, the same copy comes back rather than another downsample.
    #expect(BitmapMips.image(src, scale: 0.25) === quarter)

    // Never shrunk into nothing.
    let tiny = BitmapMips.image(src, scale: 0.001)
    #expect(tiny.width >= 32)
}

/// A group shadow's transparency layer is bounded to the group. The bound must
/// still hold the whole shadow, or a blur is cut off flat at its edge.
@Test func aBoundedGroupShadowStillReachesPastTheGroup() throws {
    var dot = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 40, height: 40),
                                       transform: nil), closed: true))
    dot.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
    dot.style.fills = [Fill(paint: .color(.black))]
    var g = Layer(kind: .group([dot]))
    g.frame = CGRect(x: 40, y: 40, width: 40, height: 40)
    var s = Shadow()
    s.offset = .zero
    s.blur = 10
    s.color = Color(r: 0, g: 0, b: 0, a: 1)
    g.style.shadows = [s]

    var page = Page(name: "p")
    page.layers = [g]
    let img = try #require(Renderer(background: Color(r: 1, g: 1, b: 1, a: 1))
        .render(page: page, maxDimension: 120, bounds: CGRect(x: 0, y: 0, width: 120, height: 120)))
    #expect(img.width == 120)
    let px = try #require(pixels(of: img))
    func gray(_ x: Int, _ y: Int) -> Int { Int(px[(y * 120 + x) * 4]) }

    // Just outside the dot, inside the blur: darker than paper.
    #expect(gray(60, 36) < 250)
    #expect(gray(60, 84) < 250)
    // Well outside three blur radii: paper.
    #expect(gray(60, 5) == 255)
    #expect(gray(5, 60) == 255)
}

private func pixels(of img: CGImage) -> [UInt8]? {
    let w = img.width, h = img.height
    var out = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return out
}
