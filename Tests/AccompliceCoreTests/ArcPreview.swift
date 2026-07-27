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

/// Renders one artboard from a file by name, so a scripted edit can be looked at.
@Test func renderArtboardPreview() throws {
    let env = ProcessInfo.processInfo.environment
    guard let file = env["ART_FILE"], let want = env["ART_NAME"],
          let out = env["ART_OUT"] else { return }

    let (doc, images) = try AcmplcFile.read(url: URL(fileURLWithPath: file))
    for page in doc.pages {
        guard let id = page.layers.first(where: { $0.name == want })?.id,
              let iso = page.isolate(id) else { continue }
        let img = try #require(Renderer(images: images).render(page: iso.page,
                                                              maxDimension: 700,
                                                              bounds: iso.bounds))
        try #require(Renderer.png(img)).write(to: URL(fileURLWithPath: out))
        return
    }
    Issue.record("no artboard named \(want)")
}

/// A masked group, rendered, so the clipping can be looked at rather than asserted.
@Test func renderMaskPreview() throws {
    guard let out = ProcessInfo.processInfo.environment["MASK_OUT"] else { return }

    func stripes() -> Layer {
        // Stands in for a photo: obvious enough that a wrong clip is unmistakable.
        let p = CGMutablePath()
        for i in 0..<20 {
            p.addRect(CGRect(x: CGFloat(i) * 20, y: 0, width: 10, height: 400))
        }
        var l = Layer(kind: .path(p, closed: true))
        l.name = "Stripes"
        l.frame = CGRect(x: -50, y: -50, width: 400, height: 400)
        l.style.fills = [Fill(paint: .color(Color(r: 0.85, g: 0.15, b: 0.1, a: 1)))]
        return l
    }

    var circle = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 300, height: 300),
                                          transform: nil), closed: true))
    circle.name = "Circle"
    circle.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    circle.hasClippingMask = true

    var group = Layer(kind: .group([circle, stripes()]))
    group.name = "Masked"
    group.frame = CGRect(x: 20, y: 20, width: 300, height: 300)

    // The same group again, resized: the mask must scale with its contents.
    var bigger = group
    bigger.frame.origin = CGPoint(x: 360, y: 20)
    bigger.resize(to: CGSize(width: 180, height: 180))

    var page = Page(name: "masks")
    page.layers = [group, bigger]
    let img = try #require(Renderer(images: [:]).render(page: page, maxDimension: 700))
    try #require(Renderer.png(img)).write(to: URL(fileURLWithPath: out))
}
