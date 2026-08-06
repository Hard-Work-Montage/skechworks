import CoreGraphics
import Foundation
import Testing

@testable import AccompliceCore

// Hill-climbing a traced drawing into place.
//
// Exists because asking a model to correct its own placement makes it worse —
// 70% came back 62% from the model that drew it. Arithmetic is better at
// coordinates than any of them and cannot lose, which is the property most of
// these tests are about.

private let area = CGRect(x: 0, y: 0, width: 200, height: 200)

private func target() -> CGImage {
    let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ctx.setLineWidth(10)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 60, y: 40)); ctx.addLine(to: CGPoint(x: 60, y: 160))
    ctx.move(to: CGPoint(x: 140, y: 40)); ctx.addLine(to: CGPoint(x: 140, y: 160))
    ctx.strokePath()
    return ctx.makeImage()!
}

private func page(offsetBy dx: CGFloat, width: Double = 10) -> Page {
    var p = Page(name: "t")
    for x in [60.0, 140.0] {
        var spec = AddSpec()
        spec.kind = "path"
        spec.d = "M\(x + Double(dx)) 40 L\(x + Double(dx)) 160"
        spec.stroke = "#000000"
        spec.strokeWidth = width
        _ = p.add(spec)
    }
    return p
}

private func score(_ p: Page, _ ref: CGImage) -> Double {
    Compare.render(p, bounds: area, matching: ref).map { Compare.inkAgreement($0, ref) } ?? 0
}

@Test func itPullsAMisplacedDrawingBackIntoPlace() {
    let ref = target()
    let out = Refine.polish(page(offsetBy: 14), bounds: area, matching: ref, budget: 8)
    #expect(out.gained > 0.15, "expected a real gain, got \(out.gained)")
    #expect(out.score > 0.6)
}

@Test func itFixesAStrokeOfTheWrongWeight() {
    // Right place, too heavy. The one error that reads like every other one.
    let ref = target()
    let out = Refine.polish(page(offsetBy: 0, width: 22), bounds: area, matching: ref, budget: 8)
    #expect(out.gained > 0.1, "expected thickness to be corrected, got \(out.gained)")
}

@Test func itNeverReturnsSomethingWorseThanItWasGiven() {
    // The property the whole thing rests on: it is bolted onto the end of a
    // paid pipeline and must not be able to spoil what was paid for.
    let ref = target()
    for offset in [0, 3, 25, 80] as [CGFloat] {
        let start = page(offsetBy: offset)
        let out = Refine.polish(start, bounds: area, matching: ref, budget: 4)
        #expect(out.score >= out.startedAt - 0.0001,
                "offset \(offset) came back worse: \(out.startedAt) -> \(out.score)")
    }
}

@Test func anAlreadyPerfectDrawingIsLeftAlone() {
    let ref = target()
    let out = Refine.polish(page(offsetBy: 0), bounds: area, matching: ref, budget: 4)
    #expect(out.score >= 0.95)
    #expect(out.gained >= 0)
}

@Test func itRespectsTheTimeItWasGiven() {
    let ref = target()
    let started = Date()
    _ = Refine.polish(page(offsetBy: 40), bounds: area, matching: ref, budget: 2)
    // Generous slack: a sweep in progress finishes the trial it's on.
    #expect(Date().timeIntervalSince(started) < 8)
}

@Test func anEmptyPageIsHandledRatherThanCrashing() {
    let out = Refine.polish(Page(name: "empty"), bounds: area, matching: target(), budget: 2)
    #expect(out.page.layers.isEmpty)
    #expect(out.evaluations >= 1)
}

@Test func shapesInsideGroupsAreMovedToo() {
    // A trace lands its shapes inside a group, so a version that only walked the
    // top level would do nothing at all in the real pipeline.
    let ref = target()
    var inner = page(offsetBy: 14)
    var grouped = Page(name: "t")
    var group = Layer(kind: .group(inner.layers))
    group.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    grouped.layers = [ group ]
    inner = grouped
    let out = Refine.polish(inner, bounds: area, matching: ref, budget: 8)
    #expect(out.gained > 0.1, "grouped shapes were not reached: \(out.gained)")
}
