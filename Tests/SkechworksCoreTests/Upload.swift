import CoreGraphics
import Foundation
import Testing
@testable import SkechworksCore

// What goes to the services has to fit, and text has to arrive with a fill.

/// Noise compresses badly, so a modest picture makes a big PNG.
private func noisy(_ w: Int, _ h: Int) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    var seed: UInt32 = 12345
    for i in bytes.indices {
        seed = seed &* 1664525 &+ 1013904223
        bytes[i] = UInt8(truncatingIfNeeded: seed >> 24)
    }
    return bytes.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
}

@Test func aPictureTooBigToSendIsShrunkUntilItFits() throws {
    let big = noisy(1200, 1200)                       // about 5.7 MB as PNG
    let limit = 1_000_000
    let (data, scale) = try #require(Renderer.png(big, under: limit))
    #expect(data.count <= limit, "still \(data.count) bytes")
    #expect(scale < 1 && scale > 0.2, "scale \(scale)")
    let back = try #require(BitmapImage.load(data)?.image)
    #expect(back.width < 1200)
    #expect(abs(CGFloat(back.width) / CGFloat(back.height) - 1) < 0.01, "the shape has to survive")
}

@Test func aPictureThatAlreadyFitsIsSentAsItIs() throws {
    let small = noisy(100, 100)
    let (data, scale) = try #require(Renderer.png(small, under: 10_000_000))
    #expect(scale == 1)
    #expect(BitmapImage.load(data)?.image.width == 100)
}

@Test func newTextArrivesWithAFill() throws {
    var page = Page(name: "p")
    var spec = AddSpec()
    spec.kind = "text"
    spec.text = "Hello"
    let made = page.add(spec)
    let id = try #require(made)
    let layer = try #require(page.layer(id))
    #expect(layer.style.fills.count == 1)
    guard case .color(let c) = layer.style.fills[0].paint else { Issue.record("not a color fill"); return }
    #expect(c.r == 0 && c.g == 0 && c.b == 0 && c.a == 1)
}
