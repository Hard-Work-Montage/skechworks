import Testing
import Foundation
import CoreGraphics
@testable import SkechworksCore

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

    let (doc, images) = try SkechworksFile.read(url: URL(fileURLWithPath: file))
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

/// Adam's scene: artboard > group > (ellipse mask, image). Rendered before and after
/// moving the group, to see what actually happens to the mask.
@Test func renderMaskDragPreview() throws {
    guard let out = ProcessInfo.processInfo.environment["DRAG_OUT"] else { return }

    func scene(groupOffsetX: CGFloat) -> Page {
        var ellipse = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 200),
                                               transform: nil), closed: true))
        ellipse.name = "Ellipse"
        ellipse.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        ellipse.hasClippingMask = true

        let stripes = CGMutablePath()
        for i in 0..<24 { stripes.addRect(CGRect(x: CGFloat(i) * 20, y: 0, width: 10, height: 300)) }
        var photo = Layer(kind: .path(stripes, closed: true))
        photo.name = "etsy_01"
        photo.frame = CGRect(x: -20, y: -20, width: 300, height: 300)
        photo.style.fills = [Fill(paint: .color(Color(r: 0.85, g: 0.15, b: 0.1, a: 1)))]

        var group = Layer(kind: .group([ellipse, photo]))
        group.name = "Group"
        group.frame = CGRect(x: 60 + groupOffsetX, y: 60, width: 200, height: 200)

        var art = Layer(kind: .group([group]))
        art.name = "Frame"
        art.isArtboard = true
        art.backgroundColor = Color(r: 0.93, g: 0.93, b: 0.93, a: 1)
        art.frame = CGRect(x: 0, y: 0, width: 340, height: 340)

        var page = Page(name: "p")
        page.layers = [art]
        return page
    }

    // Side by side: at rest, and with the group moved left by 60.
    var both = Page(name: "both")
    both.layers = scene(groupOffsetX: 0).layers
    var shifted = scene(groupOffsetX: -60).layers
    shifted[0].frame.origin.x += 400
    both.layers.append(contentsOf: shifted)

    let img = try #require(Renderer(images: [:]).render(page: both, maxDimension: 800))
    try #require(Renderer.png(img)).write(to: URL(fileURLWithPath: out))
}

/// A group shadow next to per-child shadows, to show the difference.
@Test func renderGroupShadowPreview() throws {
    guard let out = ProcessInfo.processInfo.environment["SHADOW_OUT"] else { return }

    func dot(_ x: CGFloat, shadow: Bool) -> Layer {
        var l = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 110, height: 110),
                                         transform: nil), closed: true))
        l.frame = CGRect(x: x, y: 20, width: 110, height: 110)
        l.style.fills = [Fill(paint: .color(Color(r: 0.35, g: 0.45, b: 0.7, a: 1)))]
        if shadow {
            var s = Shadow()
            s.offset = CGSize(width: 0, height: 6)
            s.blur = 12
            s.color = Color(r: 0, g: 0, b: 0, a: 0.45)
            l.style.shadows = [s]
        }
        return l
    }

    // Left: the shadow on the group. Right: the same shadow on each child, which
    // casts one child's shadow across the next.
    var onGroup = Layer(kind: .group([dot(0, shadow: false), dot(70, shadow: false)]))
    onGroup.frame = CGRect(x: 30, y: 30, width: 200, height: 150)
    var s = Shadow()
    s.offset = CGSize(width: 0, height: 6)
    s.blur = 12
    s.color = Color(r: 0, g: 0, b: 0, a: 0.45)
    onGroup.style.shadows = [s]

    var onChildren = Layer(kind: .group([dot(0, shadow: true), dot(70, shadow: true)]))
    onChildren.frame = CGRect(x: 290, y: 30, width: 200, height: 150)

    var plate = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 520, height: 210),
                                         transform: nil), closed: true))
    plate.frame = CGRect(x: 0, y: 0, width: 520, height: 210)
    plate.style.fills = [Fill(paint: .color(Color(r: 1, g: 1, b: 1, a: 1)))]

    var page = Page(name: "s")
    page.layers = [plate, onGroup, onChildren]
    let img = try #require(Renderer(images: [:]).render(page: page, maxDimension: 780))
    try #require(Renderer.png(img)).write(to: URL(fileURLWithPath: out))
}
