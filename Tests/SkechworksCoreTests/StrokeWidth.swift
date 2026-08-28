import CoreGraphics
import Foundation
import Testing

@testable import SkechworksCore

// Measuring how thick the lines are, so the model is told rather than guessing.
//
// The number matters more than it looks. With the geometry exactly right, a
// 14-wide line drawn at 24 scores 65% and at 32 scores 50% — and the overlay
// makes that read as a placement error, so the loop spends its remaining passes
// moving shapes that were never in the wrong place.

private func page(_ side: Int = 400, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    draw(ctx)
    return ctx.makeImage()!
}

private func strokedFigure(width: CGFloat, side: Int = 400) -> CGImage {
    page(side) { ctx in
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        // Two fingers standing clear above the fist. They must not cross its
        // edge: two strokes that touch merge into one blob, and then the run
        // either side of them is the blob's width, not a line's.
        ctx.move(to: CGPoint(x: 150, y: 60)); ctx.addLine(to: CGPoint(x: 150, y: 150))
        ctx.move(to: CGPoint(x: 250, y: 60)); ctx.addLine(to: CGPoint(x: 250, y: 150))
        ctx.strokePath()
        ctx.stroke(CGRect(x: 110, y: 190, width: 180, height: 150))
    }
}

@Test func lineThicknessIsMeasuredCloseEnoughToDrawWith() {
    // Within a pixel or two is the bar: the score falls off fast enough that
    // "about right" is worth a lot and exact isn't needed.
    for drawn in [8, 14, 24, 32] as [CGFloat] {
        let stats = ImageStats.measure(strokedFigure(width: drawn))
        let measured = stats.strokeWidth * 400
        #expect(abs(measured - drawn) <= 3,
                "a \(Int(drawn))-wide line measured as \(Int(measured))")
    }
}

@Test func thicknessIsReadTheSameWayOnWhiteLinesOverBlack() {
    let inverted = page { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(16)
        ctx.move(to: CGPoint(x: 100, y: 80)); ctx.addLine(to: CGPoint(x: 100, y: 320))
        ctx.strokePath()
    }
    #expect(abs(ImageStats.measure(inverted).strokeWidth * 400 - 16) <= 3)
}

@Test func aCornerDoesNotDragTheThicknessDown() {
    // Where two strokes meet, both runs are short. The median has to shrug that
    // off or every drawing with a join reads as thinner than it is.
    let elbow = page { ctx in
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(20)
        ctx.move(to: CGPoint(x: 80, y: 80))
        ctx.addLine(to: CGPoint(x: 80, y: 300))
        ctx.addLine(to: CGPoint(x: 320, y: 300))
        ctx.strokePath()
    }
    #expect(abs(ImageStats.measure(elbow).strokeWidth * 400 - 20) <= 3)
}

@Test func aPictureWithNoInkAsksForNoThickness() {
    let blank = page { _ in }
    #expect(ImageStats.measure(blank).strokeWidthHint(for: CGSize(width: 400, height: 400)) == nil)
}

@Test func theHintArrivesInTheCoordinatesTheDrawingWillUse() {
    // Measured on a 400px source, drawn onto an 800px area: the number has to
    // be scaled for it, or it's the wrong number told confidently.
    let stats = ImageStats.measure(strokedFigure(width: 14))
    let hint = stats.strokeWidthHint(for: CGSize(width: 800, height: 800))
    #expect(hint != nil)
    let digits = hint!.compactMap { $0.isNumber ? $0 : nil }
    let stated = Int(String(digits)) ?? 0
    #expect(abs(stated - 28) <= 6, "expected roughly 28 on a doubled canvas, got \(stated)")
}

@Test func gettingThicknessWrongCostsMoreThanItLooks() {
    // The reason any of this exists. Same shape, same place, only the weight
    // differs — and the score falls far enough to swamp the loop's real signal.
    let target = strokedFigure(width: 14)
    #expect(Compare.inkAgreement(strokedFigure(width: 14), target) > 0.99)
    #expect(Compare.inkAgreement(strokedFigure(width: 24), target) < 0.7)
    #expect(Compare.inkAgreement(strokedFigure(width: 32), target) < 0.55)
}

@Test func touchingStrokesReadAsOneThickMark() {
    // The honest limit of measuring by runs: where two strokes overlap there is
    // no gap between them, so the run spans both and the ink reads as heavier
    // than any single line in it. The median keeps this from mattering while
    // most of the ink is still clean line, which is the normal case for the
    // outline drawings this path is for.
    let touching = page { ctx in
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(20)
        ctx.setLineCap(.round)
        for x in [100, 112, 124, 136] as [CGFloat] {
            ctx.move(to: CGPoint(x: x, y: 80)); ctx.addLine(to: CGPoint(x: x, y: 320))
        }
        ctx.strokePath()
    }
    #expect(ImageStats.measure(touching).strokeWidth * 400 > 24,
            "four overlapping 20-wide lines should measure as the slab they form")
}
