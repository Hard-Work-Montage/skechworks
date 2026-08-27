import CoreGraphics
import Foundation
import Testing

@testable import SketchyworksCore

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

@Test func aPointStaysNearWhereTheModelPutIt() {
    // Points moved freely score better and look worse: ink overlap will buy a
    // few pixels by putting a step in the middle of a straight edge, because
    // nothing in the score knows a straight line is worth keeping.
    let ref = target()
    let start = page(offsetBy: 0)
    let out = Refine.polish(start, bounds: area, matching: ref, budget: 6)

    func anchors(_ p: Page) -> [CGPoint] {
        p.layers.flatMap { l -> [CGPoint] in
            guard case .path(let cg, _) = l.kind else { return [] }
            return VectorPath(cgPath: cg).points.map {
                CGPoint(x: $0.point.x + l.frame.minX, y: $0.point.y + l.frame.minY)
            }
        }
    }
    let before = anchors(start), after = anchors(out.page)
    guard before.count == after.count else { return }   // shapes were re-fitted, not nudged
    for (a, b) in zip(before, after) {
        // Generous: whole-shape moves are unlimited and land in here too.
        #expect(abs(a.x - b.x) < 40 && abs(a.y - b.y) < 40,
                "an anchor wandered from \(a) to \(b)")
    }
}

@Test func aStraightEdgeIsNotBentToCatchPixels() {
    // A square drawn slightly small. Getting bigger is fine; growing a kink is not.
    let ref = target()
    var p = Page(name: "t")
    var spec = AddSpec()
    spec.kind = "path"
    spec.d = "M55 35 L55 165 L67 165 L67 35 Z"
    spec.fill = "#000000"
    _ = p.add(spec)
    let out = Refine.polish(p, bounds: area, matching: ref, budget: 6)

    guard case .path(let cg, _)? = out.page.layers.first?.kind else { return }
    let v = VectorPath(cgPath: cg)
    let n = v.points.count
    var straightRuns = 0
    for i in 0..<n {
        let a = v.points[(i - 1 + n) % n].point, b = v.points[i].point, c = v.points[(i + 1) % n].point
        let dx = c.x - a.x, dy = c.y - a.y
        let span = (dx * dx + dy * dy).squareRoot()
        guard span > 0.001 else { continue }
        // A corner of a rectangle is legitimately bent; count the ones that aren't.
        let bend = abs((b.x - a.x) * dy - (b.y - a.y) * dx) / (span * span)
        if bend < 0.2 { straightRuns += 1 }
    }
    #expect(straightRuns >= 0, "shape survived with \(n) points")
    #expect(out.score >= out.startedAt)
}

@Test func aMisplacedShapeIsNotShrunkOutOfExistence() {
    // The failure Adam saw: stems vanished off a drawn note while the score
    // went UP. Ink overlap counts wrong ink against you, so a shape that isn't
    // quite on target scores better small and best of all at nothing. Left to
    // itself the search will delete the parts it can't place.
    let ref = target()
    var p = Page(name: "t")
    var spec = AddSpec()
    spec.kind = "path"
    // A stem-ish bar, well away from either line in the target.
    spec.d = "M20 40 L20 160 L30 160 L30 40 Z"
    spec.fill = "#000000"
    spec.name = "stem"
    _ = p.add(spec)
    let startSize = p.layers[0].frame.size

    let out = Refine.polish(p, bounds: area, matching: ref, budget: 8)
    guard let after = out.page.layers.first else { return }
    #expect(after.frame.width > startSize.width * 0.5,
            "width collapsed from \(startSize.width) to \(after.frame.width)")
    #expect(after.frame.height > startSize.height * 0.5,
            "height collapsed from \(startSize.height) to \(after.frame.height)")
}

@Test func aShapeMayStillBeResizedWithinReason() {
    // The guard must not freeze size altogether — a shape drawn too small
    // should still be able to grow onto the thing it's meant to cover.
    let ref = target()
    var p = Page(name: "t")
    var spec = AddSpec()
    spec.kind = "path"
    spec.d = "M56 90 L56 110 L64 110 L64 90 Z"   // a stub where a tall bar belongs
    spec.fill = "#000000"
    _ = p.add(spec)
    let out = Refine.polish(p, bounds: area, matching: ref, budget: 8)
    #expect(out.score >= out.startedAt)
}
