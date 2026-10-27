import Testing
import CoreGraphics
import Foundation
@testable import SkechworksCore

// Adam, 2026-10-26: printed metal on color coins, brushed at 45°.

private func brushedSquare(_ brushed: Bool) -> Page {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 200, height: 200), transform: nil), closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    l.style.fills = [Fill(paint: .color(Color(r: 0.6, g: 0.6, b: 0.6, a: 1)), brushed: brushed)]
    var page = Page(name: "p"); page.layers = [l]
    return page
}

@Test func theTileIsTheSameEveryTime() throws {
    let a = try #require(Brushed.makeStreaks()), b = try #require(Brushed.makeStreaks())
    #expect(a.darken.width == Brushed.tilePixels)
    #expect(a.darkenPNG == b.darkenPNG && a.lightenPNG == b.lightenPNG, "a fixed seed, so a file looks the same wherever it opens")
}

@Test func aBrushedFillSurvivesSaveAndOnlyWritesTheKeyWhenOn() throws {
    var doc = Document(); doc.pages = [brushedSquare(true)]
    let data = try SkechworksFile.write(document: doc, images: [:])
    let fill = try #require(SkechworksFile.read(data).document.pages.first?.layers.first?.style.fills.first)
    #expect(fill.brushed)
    guard case .color(let c) = fill.paint else { Issue.record("not a color"); return }
    #expect(c.matches(Color(r: 0.6, g: 0.6, b: 0.6, a: 1)), "the color stays the one that was picked")

    var plain = Document(); plain.pages = [brushedSquare(false)]
    let json = String(decoding: try SkechworksFile.write(document: plain, images: [:]), as: UTF8.self)
    #expect(!json.contains("brushed"))
}

@Test func brushedExportsAsAPatternOverTheFill() {
    let svg = SVGWriter(images: [:]).svg(page: brushedSquare(true))
    #expect(svg.contains("<pattern id=\"brushed-dark\""))
    #expect(svg.contains("rotate(-45)"))
    #expect(svg.contains("<pattern id=\"brushed-shine-light\""))
    #expect(svg.contains("mix-blend-mode:color-dodge"))
    #expect(svg.components(separatedBy: "<path").count - 1 == 5, "the fill, then the streaks and the shine over it")
    #expect(!SVGWriter(images: [:]).svg(page: brushedSquare(false)).contains("pattern"))
}

@Test func brushedStreaksShowOnTheCanvas() throws {
    func pixels(_ brushed: Bool) throws -> [UInt8] {
        let img = try #require(Renderer(images: [:]).render(page: brushedSquare(brushed), maxDimension: 200))
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: img.width * img.height * 4)
        return (0..<(img.width * img.height)).map { p[$0 * 4] }
    }
    let flat = try pixels(false), brushed = try pixels(true)
    #expect(Set(flat).count <= 2, "a solid gray is one color")
    let spread = Int(brushed.max()!) - Int(brushed.min()!)
    #expect(spread > 30, "streaks lighten and darken the gray (spread \(spread))")
    let mean = brushed.map(Int.init).reduce(0, +) / brushed.count
    #expect(abs(mean - Int(flat[flat.count / 2])) < 25, "and it still reads as the same gray overall")
}

// Adam, 10-26: the first cut lightened dark grays far more than light ones,
// so the trees on Jerry flared. The change is a fraction of the color now.
@Test func darkGraysChangeLessThanLightOnes() throws {
    func spread(_ v: CGFloat) throws -> Int {
        var page = brushedSquare(true)
        page.layers[0].style.fills[0].paint = .color(Color(r: v, g: v, b: v, a: 1))
        let img = try #require(Renderer(images: [:]).render(page: page, maxDimension: 200))
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: img.width * img.height * 4)
        let r = (0..<(img.width * img.height)).map { Int(p[$0 * 4]) }.sorted()
        return r[r.count * 95 / 100] - r[r.count * 5 / 100]
    }
    let dark = try spread(0.16), light = try spread(0.67)
    #expect(dark < light, "dark \(dark), light \(light)")
}

@Test func theEditSignatureSeesBrushed() {
    #expect(brushedSquare(true).layers[0].contentSignature != brushedSquare(false).layers[0].contentSignature)
}
