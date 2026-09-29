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
    guard case .eraseColor(let q, let hex, _, let everywhere, _, _) = cmd else {
        Issue.record("decoded as \(cmd)"); return
    }
    #expect(hex == "#FFD700" && q.type == "image" && !everywhere)

    // "fill" is a selector key everywhere else, but a picture has no fill.
    let viaFill = try #require(DocumentCommand.decode(
        try JSONSerialization.jsonObject(with: Data(##"{"op":"knockout","fill":"#E8B040"}"##.utf8))))
    guard case .eraseColor(let q2, "#E8B040", _, _, _, _) = viaFill else {
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

@Test func numberedPicksReadHoweverTheyArrive() throws {
    for json in [##"{"op":"eraseColor","color":"#f2b448","exact":true,"patches":["C1","C3"]}"##,
                 ##"{"op":"eraseColor","color":"#f2b448","exact":true,"patches":[1,3]}"##,
                 ##"{"op":"eraseColor","color":"#f2b448","exact":true,"patches":"C1, C3"}"##] {
        let cmd = try #require(DocumentCommand.decode(try JSONSerialization.jsonObject(with: Data(json.utf8))))
        guard case .eraseColor(_, _, _, _, true, [1, 3]?) = cmd else { Issue.record("\(json) → \(cmd)"); continue }
    }
    let keep = try #require(DocumentCommand.decode(
        try JSONSerialization.jsonObject(with: Data(##"{"op":"keepSubjects","subjects":["S2"]}"##.utf8))))
    guard case .keepSubjects(_, [2]?) = keep else { Issue.record("\(keep)"); return }
    let all = try #require(DocumentCommand.decode(
        try JSONSerialization.jsonObject(with: Data(##"{"op":"removeBackground"}"##.utf8))))
    guard case .keepSubjects(_, nil) = all else { Issue.record("\(all)"); return }
    let back = try #require(DocumentCommand.decode(
        try JSONSerialization.jsonObject(with: Data(##"{"op":"putBack","erases":["E9"]}"##.utf8))))
    guard case .putBack(_, [9]) = back else { Issue.record("\(back)"); return }
}

@Test func picksComeFromTheSameListThePictureWasNumberedFrom() throws {
    let img = paintedCoin()
    let colour = Color(r: 1, g: 0.72, b: 0.2, a: 1)
    let all = KnockOut.patches(in: img, color: colour, exact: true, everywhere: true)
    #expect(all.count >= 2, "the ring and the sky's gold")
    #expect(zip(all, all.dropFirst()).allSatisfy { $0.area >= $1.area }, "biggest first")

    var layer = Layer(kind: .bitmap(imageRef: "knockout-picks.png"))
    layer.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    var page = Page(name: "p"); page.layers = [layer]
    _ = page.run([.eraseColor(LayerQuery(), hex: colour.hex, tolerance: nil, everywhere: true,
                              exact: true, patches: [2])],
                 selection: [layer.id]) { _ in img }
    let erased = try #require(page.layer(layer.id)?.erased)
    #expect(erased.count == all[1].pieces.count)
    #expect(erased.first?.bounds.intersects(all[1].box) == true)
}

@Test func puttingBackTakesThoseErasesOff() throws {
    var layer = Layer(kind: .bitmap(imageRef: "knockout-back.png"))
    layer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    layer.erased = (0..<4).map { EraseStroke(rect: CGRect(x: $0 * 20, y: 0, width: 10, height: 10)) }
    var page = Page(name: "p"); page.layers = [layer]
    let run = page.run([.putBack(LayerQuery(), erases: [2, 4, 9])], selection: [layer.id])
    #expect(run.report.contains("put back 2"), "\(run.report)")
    #expect(page.layer(layer.id)?.erased.map { $0.rect!.minX } == [0, 40])
}

@Test func keepingASubjectErasesEverythingRoundIt() throws {
    let w = 40, h = 40
    var bits = [Bool](repeating: false, count: w * h)
    for y in 10..<30 { for x in 10..<30 { bits[y * w + x] = true } }
    let dog = Subjects.Found(bits: bits, box: CGRect(x: 10, y: 10, width: 20, height: 20), area: 400)
    let rings = Subjects.background(of: [dog], w: w, h: h)
    #expect(rings.count == 1, "one piece of background")
    #expect(rings.first?.count == 2, "its edge, and the hole the dog sits in")
}

@Test func aHairlineOutlineNeverCrashesTheCanvasOrTheFile() throws {
    // What a 1px-wide patch simplifies to: its two ends. Drawn as a brush with
    // no points it trapped on every redraw, and saved it came back as one.
    let hairline = EraseStroke(polygon: [CGPoint(x: 1, y: 1), CGPoint(x: 30, y: 1)])
    var empty = EraseStroke(points: [CGPoint(x: 0, y: 0)], radius: 4)
    empty.points = []
    let good = EraseStroke(rect: CGRect(x: 0, y: 0, width: 5, height: 5))
    _ = EraseMask.image(strokes: [hairline, empty, good], size: CGSize(width: 40, height: 40))

    var layer = Layer(kind: .bitmap(imageRef: "hairline.png"))
    layer.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
    layer.erased = [hairline, empty, good]
    var page = Page(name: "p"); page.layers = [layer]
    var doc = Document(); doc.pages = [page]
    let data = try SkechworksFile.write(document: doc, images: [:])
    let back = try SkechworksFile.read(data).document
    let erased = try #require(back.pages.first?.layers.first?.erased)
    #expect(erased.count == 1 && erased.first?.rect != nil, "only the real erase survives")

    // And a file saved by 0.1.76 with the empty brush already in it still opens.
    let poisoned = String(decoding: data, as: UTF8.self)
    #expect(!poisoned.isEmpty)
}

@Test func takingEveryPatchStoresNoHairlines() throws {
    // A 1px gold line beside a gold block, flat artwork, everywhere:true.
    let ctx = CGContext(data: nil, width: 60, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(device(1, 1, 1)); ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
    ctx.setShouldAntialias(false)
    ctx.setFillColor(device(1, 0.87, 0.57))
    ctx.fill(CGRect(x: 5, y: 5, width: 30, height: 1))
    ctx.fill(CGRect(x: 5, y: 20, width: 30, height: 30))
    let img = ctx.makeImage()!
    var layer = Layer(kind: .bitmap(imageRef: "hairline-run.png"))
    layer.frame = CGRect(x: 0, y: 0, width: 60, height: 60)
    var page = Page(name: "p"); page.layers = [layer]
    _ = page.run([.eraseColor(LayerQuery(), hex: "#FFDE91", tolerance: nil, everywhere: true, exact: true, patches: nil)],
                 selection: [layer.id]) { _ in img }
    let erased = try #require(page.layer(layer.id)?.erased)
    #expect(!erased.isEmpty)
    #expect(erased.allSatisfy { ($0.polygon?.count ?? 3) >= 3 })
    _ = EraseMask.image(strokes: erased, size: layer.frame.size)
}
