import CoreGraphics
import Foundation
import Testing
@testable import AccompliceCore

// Baking several layers down into one picture.

private func bitmap(_ ref: String, _ frame: CGRect) -> Layer {
    var l = Layer(kind: .bitmap(imageRef: ref))
    l.frame = frame
    return l
}

private func png(_ w: Int, _ h: Int) -> Data {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return Renderer.png(ctx.makeImage()!)!
}

@Test func theFlattenedBoxCoversEverythingSelected() throws {
    let box = try #require(Flatten.bounds(of: [
        bitmap("a", CGRect(x: 10, y: 10, width: 100, height: 100)),
        bitmap("b", CGRect(x: 80, y: 200, width: 50, height: 50)),
    ]))
    #expect(box == CGRect(x: 10, y: 10, width: 120, height: 240))
}

@Test func aHiddenLayerIsNotPartOfThePicture() throws {
    var hidden = bitmap("b", CGRect(x: 500, y: 500, width: 50, height: 50))
    hidden.isVisible = false
    let box = try #require(Flatten.bounds(of: [
        bitmap("a", CGRect(x: 0, y: 0, width: 100, height: 100)), hidden,
    ]))
    #expect(box == CGRect(x: 0, y: 0, width: 100, height: 100))
}

@Test func theSharpestThingInTheSelectionSetsTheResolution() {
    // Flattening a 2,000-pixel piece sitting in a 500-point frame at one pixel
    // per point would throw three quarters of it away, and the layers are gone
    // by then — there is no undo for detail that was never drawn.
    let layers = [
        bitmap("small", CGRect(x: 0, y: 0, width: 500, height: 500)),
        bitmap("big", CGRect(x: 0, y: 0, width: 500, height: 500)),
    ]
    let images = ["small": png(500, 500), "big": png(2000, 2000)]
    let scale = Flatten.scale(for: layers, images: images,
                              bounds: CGRect(x: 0, y: 0, width: 500, height: 500))
    #expect(scale == 4, "expected the sharpest layer to win, got \(scale)")
}

@Test func aCarelessSelectionCannotAskForAPictureNothingCanHold() {
    let layers = [bitmap("big", CGRect(x: 0, y: 0, width: 6000, height: 6000))]
    let images = ["big": png(64, 64)]
    let scale = Flatten.scale(for: layers, images: images,
                              bounds: CGRect(x: 0, y: 0, width: 6000, height: 6000))
    #expect(scale * 6000 <= 8192, "a flatten asked for \(scale * 6000) pixels on a side")
}

@Test func layersComeBackInTheOrderTheyAreDrawn() {
    var page = Page(name: "p")
    var group = Layer(kind: .group([bitmap("inner", .zero)]))
    group.name = "G"
    page.layers = [bitmap("back", .zero), group, bitmap("front", .zero)]

    let order = page.layersInOrder().map { l -> String in
        if case .bitmap(let r) = l.kind { return r }
        return l.name
    }
    // A Set has no order; flattening in whatever order it iterates puts the
    // back layer on top about half the time.
    #expect(order == ["back", "G", "inner", "front"])
}

@Test func aPathAndAPictureFlattenTogether() throws {
    // The question worth answering rather than assuming: this renders a page
    // holding the selection, and the renderer draws paths as happily as it
    // draws pixels, so a mixed selection is one picture like any other.
    var path = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 40, height: 40), transform: nil),
                                closed: true))
    path.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
    path.style.fills = [Fill(paint: .color(Color(r: 0, g: 0, b: 1, a: 1)))]

    let picture = bitmap("a", CGRect(x: 20, y: 20, width: 60, height: 60))
    let box = try #require(Flatten.bounds(of: [path, picture]))
    #expect(box == CGRect(x: 0, y: 0, width: 80, height: 80))

    var page = Page(name: "p")
    page.layers = [path, picture]
    let out = Renderer(images: ["a": png(60, 60)]).render(page: page, maxDimension: 160, bounds: box)
    #expect(out != nil, "a mixed selection has to draw, or the tool refuses half the documents in the app")
    #expect(out?.width == 160)
}

@Test func oneLayerIsWorthFlatteningToo() throws {
    // Not gated on "more than one image". A single bitmap with erasing, a crop
    // and an adjustment on it is exactly the case that needs baking down before
    // Extend or Remove can work on it — and a lone path becoming pixels is a
    // real thing to want.
    let box = try #require(Flatten.bounds(of: [bitmap("a", CGRect(x: 5, y: 5, width: 30, height: 30))]))
    #expect(box == CGRect(x: 5, y: 5, width: 30, height: 30))
}
