import Testing
import Foundation
import CoreGraphics
@testable import SkechworksCore

// Scenes chosen for the things that have actually broken: curved text, masks, group
// shadows, and gestures previewing wrongly. Each one is a bug we shipped.

private func plate(_ w: CGFloat, _ h: CGFloat) -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil),
                              closed: true))
    l.frame = CGRect(x: 0, y: 0, width: w, height: h)
    l.style.fills = [Fill(paint: .color(Color(r: 1, g: 1, b: 1, a: 1)))]
    return l
}

private func stripes(_ frame: CGRect, name: String = "Stripes") -> Layer {
    let p = CGMutablePath()
    for i in 0..<30 { p.addRect(CGRect(x: CGFloat(i) * 20, y: 0, width: 10, height: 600)) }
    var l = Layer(kind: .path(p, closed: true))
    l.name = name
    l.frame = frame
    l.style.fills = [Fill(paint: .color(Color(r: 0.85, g: 0.15, b: 0.1, a: 1)))]
    return l
}

private func maskCircle(_ size: CGFloat) -> Layer {
    var l = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: size, height: size),
                                     transform: nil), closed: true))
    l.name = "Circle"
    l.frame = CGRect(x: 0, y: 0, width: size, height: size)
    l.hasClippingMask = true
    return l
}

@Test func goldenCurvedTextRing() {
    var page = Page(name: "coin")
    var disc = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 10, y: 10, width: 380, height: 380),
                                        transform: nil), closed: true))
    disc.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
    disc.style.fills = [Fill(paint: .color(Color(r: 0.18, g: 0.18, b: 0.18, a: 1)))]

    func ring(_ s: String, _ angle: CGFloat, _ flipped: Bool) -> Layer {
        var run = TextRun()
        run.string = s
        run.fontName = "Helvetica-Bold"
        run.fontSize = 26
        run.arc = TextArc(radius: 165, angle: angle, flipped: flipped)
        var l = Layer(kind: .text(run))
        l.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        l.style.fills = [Fill(paint: .color(Color(r: 1, g: 1, b: 1, a: 1)))]
        return l
    }
    page.layers = [plate(400, 400), disc,
                   ring("525,600 MINUTES", 0, false),
                   ring("8760 HOURS", 180, true)]
    expectGolden("curved-text-ring", page: page)
}

@Test func goldenMaskedGroup() {
    var page = Page(name: "mask")
    var group = Layer(kind: .group([maskCircle(240),
                                    stripes(CGRect(x: -40, y: -40, width: 320, height: 320))]))
    group.frame = CGRect(x: 30, y: 30, width: 240, height: 240)
    page.layers = [plate(300, 300), group]
    expectGolden("masked-group", page: page)
}

@Test func goldenDraggingInsideAMaskLeavesTheMaskPut() {
    // The bug: previewing a drag shifted composed drawables, taking each one's clip
    // with it, so the mask travelled with the art and snapped back on release. A
    // number can't express that; a picture can.
    var page = Page(name: "drag")
    let photo = stripes(CGRect(x: -40, y: -40, width: 320, height: 320))
    var group = Layer(kind: .group([maskCircle(240), photo]))
    group.frame = CGRect(x: 30, y: 30, width: 240, height: 240)
    page.layers = [plate(300, 300), group]

    // Mid-drag: the image has moved 70 left, and the circle it is clipped to must not
    // have. Rendered through the same preview path the canvas uses, so the golden is
    // the frame you would actually be looking at with the mouse still down.
    expectGolden("mask-drag-preview", page: page,
                 adjusting: [photo.id],
                 live: CGAffineTransform(translationX: -70, y: 0))
}

@Test func goldenGroupShadow() {
    var page = Page(name: "shadow")
    func dot(_ x: CGFloat) -> Layer {
        var l = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 110, height: 110),
                                         transform: nil), closed: true))
        l.frame = CGRect(x: x, y: 20, width: 110, height: 110)
        l.style.fills = [Fill(paint: .color(Color(r: 0.35, g: 0.45, b: 0.7, a: 1)))]
        return l
    }
    var g = Layer(kind: .group([dot(0), dot(70)]))
    g.frame = CGRect(x: 30, y: 30, width: 200, height: 150)
    var s = Shadow()
    s.offset = CGSize(width: 0, height: 6)
    s.blur = 12
    s.color = Color(r: 0, g: 0, b: 0, a: 0.45)
    g.style.shadows = [s]
    page.layers = [plate(280, 220), g]
    expectGolden("group-shadow", page: page)
}

@Test func goldenSimplifiedPathKeepsItsShape() {
    var page = Page(name: "simplify")
    let cg = CGMutablePath()
    for i in 0..<160 {
        let a = CGFloat(i) / 160 * 2 * .pi
        // A wobbly blob: enough detail that a bad simplify is obvious.
        let r = 110 + 18 * cos(a * 5)
        let p = CGPoint(x: 150 + r * cos(a), y: 150 + r * sin(a))
        i == 0 ? cg.move(to: p) : cg.addLine(to: p)
    }
    cg.closeSubpath()
    var vp = VectorPath(cgPath: cg)
    vp.simplify(tolerance: 1.5)

    var l = Layer(kind: .path(vp.cgPath(), closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    l.style.fills = [Fill(paint: .color(Color(r: 0.2, g: 0.5, b: 0.3, a: 1)))]
    page.layers = [plate(300, 300), l]
    expectGolden("simplified-blob", page: page)
}

@Test func goldenBooleanOperations() {
    // All four, side by side. Bounding boxes can't tell Difference from Union — only
    // looking at it can.
    var page = Page(name: "bool")
    page.layers = [plate(680, 200)]

    func pair(_ x: CGFloat, _ op: BooleanOp) {
        func disc(_ dx: CGFloat, _ name: String) -> Layer {
            var l = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 90, height: 90),
                                             transform: nil), closed: true))
            l.name = name
            l.frame = CGRect(x: x + dx, y: 55, width: 90, height: 90)
            l.style.fills = [Fill(paint: .color(Color(r: 0.25, g: 0.35, b: 0.7, a: 1)))]
            return l
        }
        let a = disc(0, "a\(x)"), b = disc(50, "b\(x)")
        page.layers.append(a)
        page.layers.append(b)
        page.combine([a.id, b.id], op: op)
    }
    pair(20, .union)
    pair(190, .subtract)
    pair(360, .intersect)
    pair(530, .difference)

    expectGolden("boolean-operations", page: page, maxDimension: 680)
}

@Test func goldenErasedBitmap() throws {
    // A real image, erased three ways: hard, soft, and a dragged stroke. Numbers can
    // say the mask is right; only a picture says the softness looks like softness.
    let side = 200
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let checks = { () -> CGImage? in
              for y in 0..<10 {
                  for x in 0..<10 {
                      ctx.setFillColor(red: (x + y).isMultiple(of: 2) ? 0.2 : 0.75,
                                       green: 0.35, blue: 0.6, alpha: 1)
                      ctx.fill(CGRect(x: x * 20, y: y * 20, width: 20, height: 20))
                  }
              }
              return ctx.makeImage()
          }(),
          let png = Renderer.png(checks) else {
        Issue.record("couldn't build the test image"); return
    }

    func photo(_ x: CGFloat, _ strokes: [EraseStroke]) -> Layer {
        var l = Layer(kind: .bitmap(imageRef: "checks"))
        l.frame = CGRect(x: x, y: 20, width: 200, height: 200)
        l.erased = strokes
        return l
    }
    let centre = CGPoint(x: 100, y: 100)
    var page = Page(name: "erase")
    page.layers = [
        plate(700, 240),
        photo(20, [EraseStroke(points: [centre], radius: 60, softness: 0)]),
        photo(250, [EraseStroke(points: [centre], radius: 60, softness: 1)]),
        photo(480, [EraseStroke(points: [CGPoint(x: 40, y: 60), CGPoint(x: 160, y: 140)],
                                radius: 28, softness: 0.6)]),
    ]
    expectGolden("erased-bitmap", page: page, images: ["checks": png], maxDimension: 700)
}
