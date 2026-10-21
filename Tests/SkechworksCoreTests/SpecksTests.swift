import Testing
import CoreGraphics
import Foundation
@testable import SkechworksCore

private func device(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, 1])!
}

/// White, 200 square, y-up as drawn: a big black letter bar, a 3-pixel dot
/// and an 8-pixel dot on the left, and the same two dots on the right.
private func speckled() -> CGImage {
    let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(device(1, 1, 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    ctx.setFillColor(device(0, 0, 0))
    ctx.fill(CGRect(x: 20, y: 90, width: 160, height: 20))
    for x in [30, 150] {
        ctx.fill(CGRect(x: x, y: 40, width: 3, height: 3))
        ctx.fill(CGRect(x: x, y: 150, width: 8, height: 8))
    }
    return ctx.makeImage()!
}

/// Dark at (x, y), y-down as the picture reads.
private func dark(_ image: CGImage, _ x: Int, _ y: Int) -> Bool {
    let w = image.width, h = image.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return px[(y * w + x) * 4] < 128
}

@Test func smallDotsGoAndBigOnesWaitForABiggerSize() throws {
    // y-down: the 3-pixel dots sit at rows 157...159, the 8-pixel ones at
    // 42...49, the bar at 90...109.
    let first = try #require(Specks.remove(from: speckled(), size: 4))
    #expect(first.removed == 2)
    #expect(!dark(first.image, 31, 158), "the small dot is gone")
    #expect(dark(first.image, 33, 45), "the bigger dot waits")
    #expect(dark(first.image, 100, 100), "the bar stays")

    let again = try #require(Specks.remove(from: first.image, size: 10))
    #expect(again.removed == 2)
    #expect(!dark(again.image, 33, 45), "a bigger size takes the next ones")
    #expect(dark(again.image, 100, 100), "the bar still stays")
    #expect(try #require(Specks.remove(from: again.image, size: 10)).removed == 0)
}

@Test func aBoxCleansOnlyInsideIt() throws {
    // Left half only.
    let r = try #require(Specks.remove(from: speckled(), size: 10, within: CGRect(x: 0, y: 0, width: 100, height: 200)))
    #expect(r.removed == 2)
    #expect(!dark(r.image, 31, 158) && !dark(r.image, 33, 45), "the left dots go")
    #expect(dark(r.image, 151, 158) && dark(r.image, 153, 45), "the right dots stay")
    #expect(dark(r.image, 50, 100) && dark(r.image, 150, 100), "the bar crosses the box and stays")
}

@Test func removeSpecksReadsFromTheModel() throws {
    let cmd = try #require(DocumentCommand.decode(
        try JSONSerialization.jsonObject(with: Data(##"{"op":"removeSpecks","type":"image","size":8}"##.utf8))))
    guard case .removeSpecks(_, 8?) = cmd else { Issue.record("\(cmd)"); return }
    let bare = try #require(DocumentCommand.decode(
        try JSONSerialization.jsonObject(with: Data(##"{"op":"despeckle"}"##.utf8))))
    guard case .removeSpecks(_, nil) = bare else { Issue.record("\(bare)"); return }
}
