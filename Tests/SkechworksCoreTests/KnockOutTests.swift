import Testing
import CoreGraphics
import Foundation
@testable import SkechworksCore

/// Colours straight into the picture's own space. A generic colour gets
/// converted on the way in, and orange drifts six degrees toward gold.
private func device(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, 1])!
}

/// A painted coin in miniature: a gold ring outlined in black on white, and
/// inside it a sky that runs from orange through the same gold to yellow with
/// no outline anywhere. The ring is what "remove the gold" means. The sky is
/// what it must leave alone.
private func paintedCoin(size: Int = 200) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size)
    ctx.setFillColor(device(1, 1, 1))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // Black outline, gold ring, black outline.
    ctx.setFillColor(device(0, 0, 0))
    ctx.fillEllipse(in: CGRect(x: 8, y: 8, width: s - 16, height: s - 16))
    ctx.setFillColor(device(1, 0.72, 0.2))
    ctx.fillEllipse(in: CGRect(x: 11, y: 11, width: s - 22, height: s - 22))
    ctx.setFillColor(device(0, 0, 0))
    ctx.fillEllipse(in: CGRect(x: 30, y: 30, width: s - 60, height: s - 60))

    // The sky: orange, with a sun in the middle whose glow runs yellow
    // through the ring's exact gold and out to the orange. No edge anywhere.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 33, y: 33, width: s - 66, height: s - 66))
    ctx.clip()
    ctx.setFillColor(device(1, 0.45, 0))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    let colours = [device(1, 0.95, 0.3),
                   device(1, 0.72, 0.2),
                   device(1, 0.45, 0)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours,
                              locations: [0, 0.5, 1])!
    let sun = CGPoint(x: s / 2, y: s / 2)
    ctx.drawRadialGradient(gradient, startCenter: sun, startRadius: 0, endCenter: sun,
                           endRadius: 45, options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

@Test func erasingGoldTakesTheOutlinedRingAndLeavesTheSky() throws {
    let img = paintedCoin()
    let (bits, w, _) = try #require(KnockOut.mask(in: img, color: Color(r: 1, g: 0.84, b: 0, a: 1),
                                                  tolerance: KnockOut.defaultTolerance,
                                                  everywhere: false))
    // CGContext's origin is bottom-left and the mask's is top-left; a ring and
    // a centred sky read the same either way up.
    #expect(bits[100 * w + 20], "the ring, left side")
    #expect(bits[100 * w + 179], "the ring, right side")
    #expect(!bits[100 * w + 100], "the sun")
    #expect(!bits[100 * w + 122] && !bits[122 * w + 100], "the gold glow round it")
    #expect(!bits[60 * w + 100], "the orange sky")
    #expect(!bits[3 * w + 3], "the white outside")
}

@Test func everywhereTakesTheSkyGoldToo() throws {
    let img = paintedCoin()
    let (bits, w, _) = try #require(KnockOut.mask(in: img, color: Color(r: 1, g: 0.72, b: 0.2, a: 1),
                                                  tolerance: KnockOut.defaultTolerance,
                                                  everywhere: true))
    #expect(bits[100 * w + 20])
    #expect(bits[100 * w + 122], "flat-artwork mode has no edge test")
}

@Test func theRingComesBackAsOnePatchWithItsHole() throws {
    let patches = KnockOut.rings(in: paintedCoin(), color: Color(r: 0.9, g: 0.7, b: 0.25, a: 1))
    #expect(patches.count == 1)
    #expect(patches.first?.count == 2, "outside edge, then the hole the sky sits in")
}

@Test func eraseColorReadsFromChatAndLandsAsErases() throws {
    let json = ##"{"op":"eraseColor","type":"image","color":"#FFD700"}"##
    let cmd = try #require(DocumentCommand.decode(
        try JSONSerialization.jsonObject(with: Data(json.utf8))))
    guard case .eraseColor(let q, let hex, _, let everywhere) = cmd else {
        Issue.record("decoded as \(cmd)"); return
    }
    #expect(hex == "#FFD700" && q.type == "image" && !everywhere)

    // "fill" is a selector key everywhere else, but a picture has no fill.
    let viaFill = try #require(DocumentCommand.decode(
        try JSONSerialization.jsonObject(with: Data(##"{"op":"knockout","fill":"#E8B040"}"##.utf8))))
    guard case .eraseColor(let q2, "#E8B040", _, _) = viaFill else {
        Issue.record("decoded as \(viaFill)"); return
    }
    #expect(q2.fill == nil)

    var layer = Layer(kind: .bitmap(imageRef: "knockout-coin.png"))
    layer.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
    var page = Page(name: "Front")
    page.layers = [layer]
    let img = paintedCoin()
    let run = page.run([cmd], selection: []) { _ in img }
    #expect(run.report.contains("1 patch"), "\(run.report)")
    let erased = try #require(page.layer(layer.id)?.erased)
    #expect(erased.count == 1)
    // Stored in layer points: the picture is 200 pixels in a 400-point frame.
    let box = try #require(erased.first?.bounds)
    #expect(box.width > 330 && box.width < 400, "\(box)")

    var noPixels = Page(name: "Front")
    noPixels.layers = [layer]
    #expect(noPixels.run([cmd]).report.contains("needs the app"))
}
