import Testing
import CoreGraphics
@testable import SkechworksCore

private let maroon = Color(r: 0.2, g: 0, b: 0, a: 0.5)

@Test func aSolidFillBecomesItsColourFadingOut() {
    let g = Gradient.fade(from: maroon)
    #expect(g.direction == .vertical)
    #expect(g.stops.count == 2)
    #expect(g.stops[0].color.matches(maroon))
    #expect(g.stops[1].color.matches(Color(r: 0.2, g: 0, b: 0, a: 0)), "same colour, clear")
}

@Test func directionReadsAndSetsBothWays() {
    var g = Gradient.fade(from: maroon)
    g.setDirection(.horizontal)
    #expect(g.direction == .horizontal)
    #expect(g.from == CGPoint(x: 0, y: 0.5) && g.to == CGPoint(x: 1, y: 0.5))
    g.from = CGPoint(x: 0, y: 0); g.to = CGPoint(x: 1, y: 1)
    #expect(g.direction == nil, "a diagonal import is neither")
    g.kind = .radial
    g.setDirection(.vertical)
    #expect(g.kind == .linear && g.direction == .vertical)
}

@Test func reverseFlipsTheStopsNotTheLine() {
    var g = Gradient.fade(from: maroon)
    g.stops.append((0.25, .black))
    g.reverse()
    #expect(g.direction == .vertical)
    #expect(g.stops.map(\.position) == [0, 0.75, 1])
    #expect(g.stops[0].color.a == 0, "the clear end is first now")
    #expect(g.stops[2].color.matches(maroon))
}

@Test func aGradientFillKeepsItsOpacityThroughSaveAndExport() throws {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 40), transform: nil), closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
    var g = Gradient.fade(from: maroon)
    g.setDirection(.horizontal)
    l.style.fills = [Fill(paint: .gradient(g), opacity: 0.5)]
    var page = Page(name: "p"); page.layers = [l]
    var doc = Document(); doc.pages = [page]

    let back = try SkechworksFile.read(SkechworksFile.write(document: doc, images: [:])).document
    let fill = try #require(back.pages.first?.layers.first?.style.fills.first)
    #expect(abs(fill.opacity - 0.5) < 0.001)
    guard case .gradient(let g2) = fill.paint else { Issue.record("not a gradient"); return }
    #expect(g2.direction == .horizontal)
    #expect(abs(g2.stops[0].color.a - 0.5) < 0.001)

    let svg = SVGWriter(images: [:]).svg(page: page)
    #expect(svg.contains("<linearGradient"))
    #expect(svg.contains("x1=\"0\"") && svg.contains("x2=\"1\""))
    #expect(svg.contains("stop-opacity=\"0.250\""), "stop alpha times fill opacity")
}
