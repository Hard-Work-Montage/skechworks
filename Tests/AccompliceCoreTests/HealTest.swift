import CoreGraphics
import Foundation
import Testing

@testable import AccompliceCore

// Filling a hole from what surrounds it, with no model.
//
// The thing being proved is not "it produces pixels" but "it knows when not
// to". A flat cartoon and a gravel path both come back filled; only one of
// them should come back trusted, because on the other one this method makes a
// smear and a model is worth paying for.

private func canvas(_ w: Int, _ h: Int, _ paint: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    paint(ctx)
    return ctx.makeImage()!
}

private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    var b = [UInt8](repeating: 0, count: 4)
    b.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
    }
    return (Int(b[0]), Int(b[1]), Int(b[2]))
}

@Test func aBlotOnAFlatColourJustGoes() {
    // A squirrel's eye on a flat red mask, in miniature.
    let image = canvas(200, 200) { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0.72, green: 0.28, blue: 0.10, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 85, y: 85, width: 30, height: 34))
    }
    let attempt = Heal.fill(image, box: CGRect(x: 80, y: 80, width: 40, height: 44))
    guard let attempt else { Issue.record("no fill"); return }

    #expect(attempt.isTrusted)
    // Dead centre of where the eye was is now the mask's own red.
    let (r, g, b) = pixel(attempt.image, 100, 100)
    #expect(abs(r - 184) <= 3 && abs(g - 71) <= 3 && abs(b - 26) <= 3)
}

@Test func aSmoothGradientIsContinuedNotFlattened() {
    let image = canvas(200, 200) { ctx in
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let gradient = CGGradient(colorsSpace: space,
                                  colors: [CGColor(gray: 0.1, alpha: 1),
                                           CGColor(gray: 0.9, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 200, y: 0), options: [])
    }
    let attempt = Heal.fill(image, box: CGRect(x: 80, y: 80, width: 40, height: 40))
    guard let attempt else { Issue.record("no fill"); return }

    #expect(attempt.isTrusted)
    // The ramp still climbs across the filled patch rather than going flat.
    let left = pixel(attempt.image, 82, 100).0
    let right = pixel(attempt.image, 117, 100).0
    #expect(right - left > 20)
}

@Test func aHardEdgeThroughTheHoleIsNotTrusted() {
    // Two blocks meeting down the middle. Averaging across that edge smears it,
    // and the fill has to notice rather than hand over a blur.
    let image = canvas(200, 200) { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 200))
    }
    let attempt = Heal.fill(image, box: CGRect(x: 70, y: 80, width: 60, height: 40))
    guard let attempt else { Issue.record("no fill"); return }
    #expect(!attempt.isTrusted)
}

@Test func noiseIsNotTrustedEither() {
    // Stand-in for gravel or foliage: no structure this method can continue.
    var seed: UInt64 = 0x9E3779B97F4A7C15
    let image = canvas(200, 200) { ctx in
        for y in 0..<200 {
            for x in 0..<200 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let v = Double((seed >> 33) & 0xFF) / 255
                ctx.setFillColor(CGColor(gray: v, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }
    let attempt = Heal.fill(image, box: CGRect(x: 80, y: 80, width: 40, height: 40))
    guard let attempt else { Issue.record("no fill"); return }
    #expect(!attempt.isTrusted)
}

@Test func nothingOutsideTheBoxMoves() {
    let image = canvas(200, 200) { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0.72, green: 0.28, blue: 0.10, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 85, y: 85, width: 30, height: 30))
        // A landmark well clear of the box.
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 10, width: 8, height: 8))
    }
    let attempt = Heal.fill(image, box: CGRect(x: 80, y: 80, width: 40, height: 40))
    guard let attempt else { Issue.record("no fill"); return }

    #expect(pixel(attempt.image, 14, 14) == (0, 255, 0))
    // And the pixel just outside the box is untouched mask red.
    let (r, g, b) = pixel(attempt.image, 78, 100)
    #expect(abs(r - 184) <= 2 && abs(g - 71) <= 2 && abs(b - 26) <= 2)
}

@Test func aBoxThatSwallowsTheWholePictureIsRefused() {
    let image = canvas(64, 64) { ctx in
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    #expect(Heal.fill(image, box: CGRect(x: 0, y: 0, width: 64, height: 64)) == nil)
}

@Test func aBigHoleStillFinishesQuickly() {
    let image = canvas(900, 900) { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0.72, green: 0.28, blue: 0.10, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 900))
    }
    let started = Date()
    let attempt = Heal.fill(image, box: CGRect(x: 250, y: 250, width: 400, height: 400))
    let seconds = Date().timeIntervalSince(started)
    #expect(attempt != nil)
    // Coarse-first is the whole point: relaxing a 400px hole one pass at a time
    // would take thousands of passes and this would be a progress bar. Measured
    // at 93ms in release, which is the build anyone actually runs; a debug build
    // bounds-checks every one of those array reads and takes about a hundred
    // times as long, so the budget here has to know which it is.
    #if DEBUG
    #expect(seconds < 20.0)
    #else
    #expect(seconds < 0.5)
    #endif
}

// Calibration. Prints the numbers the threshold is picked from, so changing it
// is an argument about data rather than taste.
@Test func theScoresSeparateTheCasesWithRoomToSpare() {
    let flat = canvas(200, 200) { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0.72, green: 0.28, blue: 0.10, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 85, y: 85, width: 30, height: 30))
    }
    let gradient = canvas(200, 200) { ctx in
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(gray: 0.1, alpha: 1),
                                    CGColor(gray: 0.9, alpha: 1)] as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 200, y: 0), options: [])
    }
    let edge = canvas(200, 200) { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 200))
    }
    var seed: UInt64 = 0x9E3779B97F4A7C15
    let noise = canvas(200, 200) { ctx in
        for y in 0..<200 {
            for x in 0..<200 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                ctx.setFillColor(CGColor(gray: Double((seed >> 33) & 0xFF) / 255, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }
    let box = CGRect(x: 80, y: 80, width: 40, height: 40)
    for (name, image) in [("flat", flat), ("gradient", gradient), ("edge", edge), ("noise", noise)] {
        let a = Heal.fill(image, box: box)
        print(String(format: "%-9s error %6.2f  spread %6.2f  trusted %@",
                     (name as NSString).utf8String!, a?.error ?? -1, a?.spread ?? -1,
                     (a?.isTrusted ?? false) ? "yes" : "no"))
    }
}
