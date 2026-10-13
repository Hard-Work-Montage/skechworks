import CoreGraphics
import Foundation
import Testing
@testable import SkechworksCore

// What a traced coin costs. A colour coin with dots laid over its white areas is
// sixteen thousand shapes, and every case here was a click, a save or a redraw
// that took seconds on one before it was a test.

private func square(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat = 10) -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: side, height: side), transform: nil), closed: true))
    l.frame = CGRect(x: x, y: y, width: side, height: side)
    l.style.fills = [Fill(paint: .color(Color(r: 0, g: 0, b: 0, a: 1)))]
    return l
}

private func page(_ layers: [Layer]) -> Page {
    var p = Page(name: "p")
    p.layers = layers
    return p
}

private func border(_ thickness: CGFloat) -> Border {
    var b = Border()
    b.thickness = thickness
    return b
}

private func board(_ kids: [Layer], size: CGFloat = 200) -> Layer {
    var b = Layer(kind: .group(kids))
    b.isArtboard = true
    b.frame = CGRect(x: 0, y: 0, width: size, height: size)
    b.backgroundColor = Color(r: 1, g: 1, b: 1, a: 1)
    return b
}

@Test func numbersAreWrittenExactlyAsPrintfWroteThem() {
    // The fast formatter replaced String(format: "%.3f"). Files written before and
    // after have to agree to the byte, halves and negatives included.
    var g = SystemRandomNumberGenerator()
    var values: [CGFloat] = [0, -0.0001, 0.0005, 0.9996, 999.9995, -12.3456, 1e11, 1e13, 0.5, 1.0005, 2.5e-7]
    for _ in 0..<20_000 { values.append(CGFloat.random(in: -5000...5000, using: &g)) }
    for i in -2000...2000 { values.append((CGFloat(i) + 0.5) / 1000) }
    for v in values {
        let old = v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%.3f", v)
        #expect(fmt(v) == old, "\(v)")
    }
}

@Test func aDrawableKnowsItsBoxWithoutBeingAsked() {
    let shapes = Compose.flatten(page([board([square(20, 30)])]).layers).filter { !$0.isArtboardBackground }
    #expect(shapes.count == 1)
    #expect(shapes[0].pathBounds == CGRect(x: 20, y: 30, width: 10, height: 10))

    // Swapping the path keeps the box honest.
    var d = shapes[0]
    d.path = CGPath(rect: CGRect(x: 0, y: 0, width: 3, height: 4), transform: nil)
    #expect(d.pathBounds == CGRect(x: 0, y: 0, width: 3, height: 4))
    d.path = nil
    #expect(d.pathBounds == nil)
}

@Test func aBoardsClipIsSkippedOnlyWhenItCannotCutAnything() {
    let shapes = Compose.flatten(page([board([square(20, 30), square(195, 30), square(50, 50)])]).layers).filter { !$0.isArtboardBackground }
    let inside = shapes[0], overTheEdge = shapes[1]
    #expect(Renderer.clipIsMoot(inside.clip!, for: inside))
    #expect(!Renderer.clipIsMoot(overTheEdge.clip!, for: overTheEdge))

    // A fat stroke or a shadow reaches further than the path does.
    var stroked = shapes[2]
    stroked.style.borders = [border(40)]
    #expect(!Renderer.clipIsMoot(stroked.clip!, for: stroked))

    // A clip that is not a plain rectangle always clips.
    let oval = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 200), transform: nil)
    #expect(!Renderer.clipIsMoot(oval, for: inside))
}

@Test func skippingTheClipChangesNoPixel() throws {
    // Shapes inside the board, across its edge and wholly outside it.
    var kids: [Layer] = []
    for i in 0..<60 { kids.append(square(CGFloat(i * 4) - 10, CGFloat((i * 37) % 210) - 5, 9)) }
    let drawables = Compose.flatten(page([board(kids)]).layers)

    func paint(_ ds: [Drawable]) -> Data {
        let ctx = CGContext(data: nil, width: 260, height: 260, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 30, y: 30)
        Renderer().draw(drawables: ds, in: ctx)
        return Data(bytes: ctx.data!, count: ctx.bytesPerRow * ctx.height)
    }
    // An oval the size of the page clips nothing the board's rectangle does not,
    // but is not a rectangle, so every shape takes the clipped path.
    let always = drawables.map { d -> Drawable in
        var d = d
        if let c = d.clip {
            d.clip = c.intersection(CGPath(rect: CGRect(x: -1000, y: -1000, width: 3000, height: 3000), transform: nil))
        }
        return d
    }
    #expect(paint(drawables) == paint(always))
}

@Test func aClickFarFromAShapeNeverTestsItsOutline() {
    let d = Compose.flatten([square(100, 100)])[0]
    #expect(Renderer.mayHit(d, at: CGPoint(x: 105, y: 105), slop: 3))
    #expect(Renderer.mayHit(d, at: CGPoint(x: 97, y: 105), slop: 3))     // within the slop
    #expect(!Renderer.mayHit(d, at: CGPoint(x: 80, y: 105), slop: 3))

    // A wide stroke is still clickable out where it paints.
    var stroked = d
    stroked.style.borders = [border(30)]
    #expect(Renderer.mayHit(stroked, at: CGPoint(x: 88, y: 105), slop: 3))
}

@Test func hitTestingStillFindsTheTopShape() {
    let back = square(10, 10, 50), front = square(30, 30, 50)
    let page = page([back, front])
    let r = Renderer()
    #expect(r.hitTest(page: page, at: CGPoint(x: 40, y: 40))?.id == front.id)
    #expect(r.hitTest(page: page, at: CGPoint(x: 15, y: 15))?.id == back.id)
    #expect(r.hitTest(page: page, at: CGPoint(x: 150, y: 150)) == nil)
}

@Test func anArchivePackedInParallelReadsBackWhole() throws {
    var entries: [ZipEntry] = []
    for i in 0..<12 {
        let text = String(repeating: "entry \(i) M12.345 6.789L1 2Z ", count: 400 + i * 50)
        entries.append(ZipEntry(name: "pages/\(i).json", data: Data(text.utf8)))
    }
    // Already-compressed bytes are stored as they are.
    let png = Data([0x89, 0x50, 0x4E, 0x47] + (0..<500).map { UInt8($0 % 251) })
    entries.append(ZipEntry(name: "assets/a.png", data: png))

    let archive = Zip.write(entries, offsetBase: 0)
    let back = try Zip.read(archive)
    #expect(back.count == entries.count)
    for e in entries {
        #expect(back[e.name] == e.data, "\(e.name)")
    }
    // Same bytes every time, whatever order the packers finished in.
    #expect(Zip.write(entries, offsetBase: 0) == archive)
}
