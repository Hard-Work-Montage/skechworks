import CoreGraphics
import Foundation
import Testing
@testable import AccompliceCore

// Picking an area of one colour by clicking in it.

/// Two flat patches with a hard black line between them — the app's own artwork
/// in miniature.
private func twoPatches(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.18, green: 0.62, blue: 0.42, alpha: 1))   // green
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(red: 0.96, green: 0.87, blue: 0.70, alpha: 1))   // cream, top half
    ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))
    ctx.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1))   // the line between
    ctx.fill(CGRect(x: 0, y: h / 2 - 3, width: w, height: 6))
    return ctx.makeImage()!
}

@Test func clickingAPatchSelectsThatPatchAndStopsAtTheOutline() throws {
    let img = twoPatches(200, 200)
    let region = try #require(Wand.region(in: img, at: CGPoint(x: 100, y: 150), tolerance: 32))
    let count = region.bits.filter { $0 }.count

    // The half it was clicked in, near enough — not the other half, and not the
    // whole picture. The black line is what stops it.
    #expect(count > 200 * 90, "selected only \(count) pixels, expected most of a half")
    #expect(count < 200 * 110, "selected \(count) pixels, which is more than one half")
}

@Test func theOutlineComesBackAsAHandfulOfPointsNotThousands() throws {
    let img = twoPatches(200, 200)
    let outline = try #require(Wand.outline(in: img, at: CGPoint(x: 100, y: 150)))

    // A traced boundary has a point per pixel. A rectangle needs about four,
    // and a stroke that has to be saved, reopened and undone cannot carry eight
    // hundred.
    #expect(outline.count < 24, "outline came back with \(outline.count) points")
    #expect(outline.count >= 4)
}

@Test func aClickOnNothingSelectsNothing() {
    let img = twoPatches(100, 100)
    #expect(Wand.outline(in: img, at: CGPoint(x: -5, y: 50)) == nil)
    #expect(Wand.outline(in: img, at: CGPoint(x: 500, y: 50)) == nil)
}

@Test func transparencyIsItsOwnAreaRatherThanAShadeOfBlack() throws {
    let ctx = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 40))      // solid black below
    let img = ctx.makeImage()!                                // clear above

    // Premultiplied, a see-through pixel is all zeroes and would match black on
    // every channel. Clicking the empty half must not select the black half.
    let empty = try #require(Wand.region(in: img, at: CGPoint(x: 40, y: 10), tolerance: 32))
    #expect(empty.bits.filter { $0 }.count < 80 * 45)
}

@Test func anOutlineSurvivesBeingSavedAndReopened() throws {
    var layer = Layer(kind: .bitmap(imageRef: "a"))
    layer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    layer.erased = [EraseStroke(polygon: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 10),
                                          CGPoint(x: 90, y: 60), CGPoint(x: 10, y: 60)])]
    var page = Page(name: "p")
    page.layers = [layer]
    var doc = Document()
    doc.pages = [page]

    let bytes = try AcmplcFile.write(document: doc, images: ["a": Data()])
    let back = try AcmplcFile.read(bytes)
    let stroke = try #require(back.document.pages.first?.layers.first?.erased.first)
    // A stroke is a decision, and a decision that does not survive a save is a
    // destructive edit wearing a nondestructive coat.
    #expect(stroke.polygon?.count == 4)
    #expect(stroke.polygon?.first == CGPoint(x: 10, y: 10))
}

@Test func everyKindOfStrokeMovesWhenTheFrameDoes() {
    // Trimming a layer to what is left moves the frame out from under the
    // strokes. Any kind that stays behind rubs its hole in the wrong place, and
    // the frame then walks further on every erase after it — which is how a
    // picture 1,120 wide ended up in a layer 3,360 wide.
    let brush = EraseStroke(points: [CGPoint(x: 10, y: 20)], radius: 4)
    let box = EraseStroke(rect: CGRect(x: 10, y: 20, width: 5, height: 5))
    let picked = EraseStroke(polygon: [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 20),
                                       CGPoint(x: 30, y: 40)])

    for stroke in [brush, box, picked] {
        let m = stroke.moved(dx: -10, dy: -20)
        #expect(m.bounds.origin.x < stroke.bounds.origin.x)
        #expect(m.bounds.origin.y < stroke.bounds.origin.y)
        // Moved by exactly what was asked, not merely somewhere else.
        #expect(abs(m.bounds.minX - (stroke.bounds.minX - 10)) < 0.001)
        #expect(abs(m.bounds.minY - (stroke.bounds.minY - 20)) < 0.001)
    }
}
