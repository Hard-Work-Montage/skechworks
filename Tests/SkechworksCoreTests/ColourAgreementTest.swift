import CoreGraphics
import Testing

@testable import SkechworksCore

// The score has to be able to see colour.
//
// It couldn't: ink agreement counted marks against background and ignored hue
// entirely, so a heart filled solid black agreed with a red one exactly as well
// as a red one did. A model painted over a picture and nothing in the loop
// could object.

private func plate(_ fill: CGColor, on background: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) -> CGImage {
    let side = 200
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.setFillColor(fill)
    ctx.fillEllipse(in: CGRect(x: 40, y: 40, width: 120, height: 120))
    return ctx.makeImage()!
}

private let red = CGColor(srgbRed: 0.93, green: 0.30, blue: 0.24, alpha: 1)
private let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

@Test func theRightColourScoresFarBetterThanTheWrongOne() {
    let target = plate(red)
    let right = Compare.inkAgreement(plate(red), target)
    let wrong = Compare.inkAgreement(plate(black), target)
    #expect(right > 0.95)
    #expect(wrong < 0.5, "black over red scored \(wrong) — the score is still colour-blind")
}

@Test func aShapeInTheRightPlaceAndWrongColourStillBeatsNothing() {
    // It should be punished, not treated as absent — the geometry is right and
    // the loop needs to be able to tell those two apart.
    let target = plate(red)
    let blank = plate(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    #expect(Compare.inkAgreement(plate(black), target) >= Compare.inkAgreement(blank, target))
}

@Test func monochromeLineArtIsUnaffected() {
    // Every edge is a ramp of part-way pixels and two renders of the same black
    // line disagree along it. Judging those on colour would punish a perfect
    // trace for having edges.
    let target = plate(black)
    #expect(Compare.inkAgreement(plate(black), target) > 0.98)
}

@Test func aNearEnoughShadeIsNotPunished() {
    // Shading a flat colour a little differently is a drawing decision, not a
    // mistake. This is here to catch black where red belongs.
    let target = plate(red)
    let close = CGColor(srgbRed: 0.88, green: 0.34, blue: 0.28, alpha: 1)
    #expect(Compare.inkAgreement(plate(close), target) > 0.9)
}

@Test func itStillWorksOnWhiteMarksOverBlack() {
    let bg = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    let target = plate(white, on: bg)
    #expect(Compare.inkAgreement(plate(white, on: bg), target) > 0.98)
    #expect(Compare.inkAgreement(plate(red, on: bg), target) < 0.6)
}
