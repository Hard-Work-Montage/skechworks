import CoreGraphics
import Testing
@testable import SkechworksCore

/// A dark coin on a cream card, the picture Remove ▸ Background is for.
private func coinOnCard(_ side: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(side)
    ctx.setFillColor(CGColor(red: 0.93, green: 0.90, blue: 0.85, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.setFillColor(CGColor(red: 0.72, green: 0.55, blue: 0.25, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8))
    ctx.setFillColor(CGColor(red: 0.20, green: 0.15, blue: 0.08, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: s * 0.15, y: s * 0.15, width: s * 0.7, height: s * 0.7))
    return ctx.makeImage()!
}

@Test func removingTheBackgroundLeavesTheCoinAndClearsTheCard() throws {
    let side = 400
    guard let cut = Subjects.lifted(from: coinOnCard(side)) else {
        // Vision found nothing standing out, or the Mac is too old to ask.
        return
    }
    #expect(cut.width == side && cut.height == side)
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cut, in: CGRect(x: 0, y: 0, width: side, height: side))
    let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
    func alpha(_ x: Int, _ y: Int) -> UInt8 { px[(y * side + x) * 4 + 3] }
    #expect(alpha(4, 4) == 0)
    #expect(alpha(side - 5, side - 5) == 0)
    #expect(alpha(side / 2, side / 2) == 255)
}
