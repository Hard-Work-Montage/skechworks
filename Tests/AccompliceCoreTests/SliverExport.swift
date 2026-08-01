import Testing
import CoreGraphics
@testable import AccompliceCore

@Test func hairlineSliversStayOutOfTheSVG() {
    // A real glyph-sized contour plus a boolean-sweep sliver: laser software
    // treats the zero-width filled contour as an unclosed shape and warns.
    let m = CGMutablePath()
    m.addRect(CGRect(x: 10, y: 10, width: 80, height: 40))
    m.move(to: CGPoint(x: 200, y: 100))
    m.addLine(to: CGPoint(x: 200.02, y: 300))
    m.addLine(to: CGPoint(x: 200.01, y: 100))
    m.closeSubpath()

    var l = Layer(kind: .path(m.copy()!, closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
    l.style.fills = [Fill(paint: .color(.black))]
    var page = Page(name: "p")
    page.layers = [l]

    let svg = SVGWriter(images: [:]).svg(page: page)
    let d = svg.components(separatedBy: " d=\"")[1].components(separatedBy: "\"")[0]
    #expect(d.contains("M10 10"), "the real contour survives")
    #expect(!d.contains("200.02"), "the sliver does not")
    #expect(d.components(separatedBy: "M").count == 2, "exactly one subpath remains")
}
