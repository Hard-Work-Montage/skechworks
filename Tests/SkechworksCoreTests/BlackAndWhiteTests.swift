import Testing
import CoreGraphics
import Foundation
@testable import SkechworksCore

private func device(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a])!
}

/// A colour coin in miniature, 400 square, y-up as CoreGraphics draws it:
/// a red leaf crossed by a black line, a dark green pine with a lighter
/// hatch line over it, a dark banner with a white letter bar in it, and a
/// clear corner.
private func paintedCoin() -> CGImage {
    let ctx = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(device(0.85, 0.75, 0.5))
    ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
    ctx.clear(CGRect(x: 0, y: 0, width: 40, height: 40))
    // The red leaf and the ink line across it.
    ctx.setFillColor(device(0.85, 0.2, 0.15))
    ctx.fill(CGRect(x: 60, y: 260, width: 120, height: 100))
    ctx.setFillColor(device(0.05, 0.05, 0.05))
    ctx.fill(CGRect(x: 60, y: 308, width: 120, height: 4))
    // The pine, darker than the ground but well above the solid cut-off in
    // its brightest channel, with an ink hatch line over it.
    ctx.setFillColor(device(0.2, 0.42, 0.25))
    ctx.fill(CGRect(x: 220, y: 260, width: 120, height: 100))
    ctx.setFillColor(device(0.04, 0.08, 0.05))
    ctx.fill(CGRect(x: 220, y: 300, width: 120, height: 3))
    // The banner, dark outright, with a light letter bar in it.
    ctx.setFillColor(device(0.2, 0.15, 0.1))
    ctx.fill(CGRect(x: 60, y: 60, width: 280, height: 90))
    ctx.setFillColor(device(0.9, 0.8, 0.55))
    ctx.fill(CGRect(x: 120, y: 95, width: 160, height: 20))
    return ctx.makeImage()!
}

/// Ink at (x, y), y-down as the picture reads, in the original's pixels.
private func ink(_ image: CGImage, _ x: Int, _ y: Int, scale: Int) -> Bool {
    let w = image.width, h = image.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    // The context's rows run bottom-up in memory order as drawn, i.e. row 0
    // of the buffer is the top of the picture.
    let i = ((y * scale) * w + x * scale) * 4
    return px[i] < 128
}

@Test func colorsGoWhiteAndInkStaysWhereItWas() throws {
    let out = try #require(BlackAndWhite.make(from: paintedCoin()))
    #expect(out.width == 800, "a small picture is worked at twice its size")
    let s = 2
    // y-down: the red leaf spans 40...140, its line at 88...92.
    #expect(!ink(out, 120, 60, scale: s), "the red leaf is paint, not ink")
    #expect(ink(out, 120, 90, scale: s), "the line across the leaf stays")
    #expect(!ink(out, 280, 60, scale: s), "the dark green pine is paint")
    #expect(ink(out, 280, 98, scale: s), "the hatch over the pine stays")
    // The banner spans 250...340, its letter bar 285...305.
    #expect(ink(out, 80, 320, scale: s), "the banner fills solid")
    #expect(!ink(out, 200, 295, scale: s), "the letter in the banner stays white")
    #expect(!ink(out, 200, 200, scale: s), "the gold ground goes white")
    #expect(!ink(out, 10, 390, scale: s), "a clear corner is white, not ink")
}

@Test func specksGoAndLinesStay() {
    // A two-pixel speck and a twenty-pixel line on a 30 × 10 grid.
    let w = 30, h = 10
    var grid = [Bool](repeating: false, count: w * h)
    grid[2 * w + 3] = true
    grid[2 * w + 4] = true
    for x in 5..<25 { grid[6 * w + x] = true }
    BlackAndWhite.despeckle(&grid, w, h, minArea: 4)
    #expect(!grid[2 * w + 3] && !grid[2 * w + 4], "the speck is dropped")
    #expect((5..<25).allSatisfy { grid[6 * w + $0] }, "the line is kept")
}
