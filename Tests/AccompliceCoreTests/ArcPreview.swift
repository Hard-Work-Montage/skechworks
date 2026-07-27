import Testing
import Foundation
import CoreGraphics
@testable import AccompliceCore

/// Renders a coin-style ring so the curve can be looked at, not just measured.
@Test func renderArcPreview() throws {
    guard let out = ProcessInfo.processInfo.environment["ARC_PREVIEW"] else { return }

    var page = Page(name: "coin")
    let size = CGRect(x: 0, y: 0, width: 500, height: 500)

    var disc = Layer(kind: .path(CGPath(ellipseIn: size.insetBy(dx: 10, dy: 10), transform: nil),
                                 closed: true))
    disc.frame = size
    disc.style.fills = [Fill(paint: .color(Color(r: 0.2, g: 0.2, b: 0.2, a: 1)))]

    func ring(_ s: String, _ angle: CGFloat, _ flipped: Bool) -> Layer {
        var run = TextRun()
        run.string = s
        run.fontName = "Helvetica-Bold"
        run.fontSize = 30
        run.color = Color(r: 1, g: 1, b: 1, a: 1)
        run.arc = TextArc(radius: 205, angle: angle, flipped: flipped)
        var l = Layer(kind: .text(run))
        l.frame = size
        l.style.fills = [Fill(paint: .color(Color(r: 1, g: 1, b: 1, a: 1)))]
        return l
    }

    page.layers = [disc,
                   ring("525,600 MINUTES", 0, false),      // top, following the curve
                   ring("8760 HOURS", 180, true)]          // bottom, upright
    let img = try #require(Renderer(images: [:]).render(page: page, maxDimension: 1000))
    let png = try #require(Renderer.png(img))
    try png.write(to: URL(fileURLWithPath: out))
}

/// The SVG that goes to the engraver has to carry the curve, not just the canvas.
@Test func curvedTextExportsAsCurvedOutlines() throws {
    var run = TextRun()
    run.string = "8760 HOURS"
    run.fontName = "Helvetica-Bold"
    run.fontSize = 30
    run.arc = TextArc(radius: 200, angle: 0)

    var l = Layer(kind: .text(run))
    l.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
    var page = Page(name: "p")
    page.layers = [l]

    let svg = SVGWriter(images: [:]).svg(page: page)
    #expect(svg.contains("<path"))
    #expect(!svg.contains("<text"))     // outlines, so the cutter needs no font

    // The bulge should match the circle it's bent around: a chord of this width on
    // a radius-200 arc rises by R(1 - cos(halfAngle)). Checking against the actual
    // geometry catches a curve that's merely *a* curve but the wrong one.
    var straight = run
    straight.arc = nil
    let curvedBox = TextOutline.path(run, in: l.frame)!.boundingBoxOfPath
    let straightBox = TextOutline.path(straight, in: l.frame)!.boundingBoxOfPath

    let halfAngle = straightBox.width / (2 * 200)
    let sagitta = 200 * (1 - cos(halfAngle))
    #expect(sagitta > 10)                                  // a real bend, not a rounding artefact
    let expected = straightBox.height + sagitta
    #expect(abs(curvedBox.height - expected) < expected * 0.12)
}
