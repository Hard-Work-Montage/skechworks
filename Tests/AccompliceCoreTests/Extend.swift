import CoreGraphics
import Foundation
import Testing
@testable import AccompliceCore

// Growing a picture and drawing the new part from what was already there.

/// Flat bands running left to right — the easy, common case. Continuing this
/// downward has exactly one right answer, and it is the bottom band's colour.
private func banded(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.83, green: 0.38, blue: 0.16, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(red: 0.18, green: 0.62, blue: 0.42, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 3))     // y-up: the lower third
    return ctx.makeImage()!
}

/// One flat colour: the case the feature is supposed to be certain about,
/// because there is nothing along the edge for the answer to depend on.
private func solid(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.83, green: 0.38, blue: 0.16, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    var bytes = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
}

@Test func growingDownwardMakesATallerPictureAndLeavesTheOldOneWhereItWas() throws {
    let src = banded(120, 90)
    let out = try #require(Extend.grow(src, toCover: CGRect(x: 0, y: 0, width: 120, height: 150)))

    #expect(out.image.width == 120)
    #expect(out.image.height == 150)
    // Growing downward adds nothing above, so the picture does not move.
    #expect(out.offset == .zero)
}

@Test func growingUpwardMovesThePictureDownByWhatWasAdded() throws {
    let src = banded(100, 100)
    let out = try #require(Extend.grow(src, toCover: CGRect(x: 0, y: -40, width: 100, height: 140)))

    #expect(out.image.height == 140)
    // The layer has to move by this, or the artwork jumps when the canvas grows.
    #expect(out.offset.y == 40)
    #expect(out.offset.x == 0)
}

@Test func theNewAreaContinuesTheColourItGrewOutOf() throws {
    let src = banded(120, 90)
    let out = try #require(Extend.grow(src, toCover: CGRect(x: 0, y: 0, width: 120, height: 140)))

    // Stated against the edge it grew from rather than against a colour name,
    // because which band is where depends on a flip nobody should have to hold
    // in their head to read a test. Whatever the last real row is, the invented
    // rows below it must be that.
    let edge = pixel(out.image, 60, 89)
    let grown = pixel(out.image, 60, 130)
    #expect(abs(edge.0 - grown.0) < 12 && abs(edge.1 - grown.1) < 12 && abs(edge.2 - grown.2) < 12,
            "the new area \(grown) should continue the edge it grew from \(edge)")
}

@Test func aBoxInsideThePictureAddsNothing() {
    let src = banded(100, 100)
    #expect(Extend.grow(src, toCover: CGRect(x: 10, y: 10, width: 50, height: 50)) == nil)
}

@Test func anAbsurdBoxIsRefusedRatherThanAllocated() {
    let src = banded(100, 100)
    // A stray drag must not ask for a canvas nothing can hold.
    #expect(Extend.grow(src, toCover: CGRect(x: 0, y: 0, width: 100, height: 9000)) == nil)
}

@Test func theStripsCoverTheNewAreaExactlyAndDoNotOverlapTheOld() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let old = CGRect(x: 20, y: 30, width: 50, height: 40)
    let strips = Extend.strips(around: old, in: frame)

    #expect(strips.allSatisfy { !$0.intersects(old) }, "a strip must never repaint the real picture")
    let area = strips.reduce(0.0) { $0 + $1.width * $1.height }
    #expect(area == frame.width * frame.height - old.width * old.height)

    // Sides before top and bottom, so the corners have filled pixels under them
    // rather than blank canvas.
    #expect(strips.first!.width < strips.last!.width)
}

@Test func aGrowThatOnlyWidensStillFillsBothSides() throws {
    let src = banded(80, 80)
    let out = try #require(Extend.grow(src, toCover: CGRect(x: -20, y: 0, width: 120, height: 80)))
    #expect(out.image.width == 120)
    #expect(out.offset.x == 20)

    // Each side continues the row it grew out of, whatever colour that is.
    let edge = pixel(out.image, 60, 70)
    for x in [ 5, 112 ] {
        let grown = pixel(out.image, x, 70)
        #expect(abs(edge.0 - grown.0) < 12 && abs(edge.1 - grown.1) < 12 && abs(edge.2 - grown.2) < 12,
                "x=\(x) got \(grown), expected to continue \(edge)")
    }
}

@Test func theGradeComesBackSoTheAnswerCanBeDoubted() throws {
    let out = try #require(Extend.grow(solid(120, 90), toCover: CGRect(x: 0, y: 0, width: 120, height: 140)))
    #expect(out.isTrusted, "flat artwork should grade as trusted, scored \(out.error)")

    // A banded picture is NOT automatically trusted, and should not be: the
    // grade looks at a strip as thick as the one being invented, and if a
    // colour changes inside that strip then continuing the edge across it is
    // genuinely wrong. That is the check working, not failing.
    let bandy = try #require(Extend.grow(banded(120, 120), toCover: CGRect(x: 0, y: 0, width: 120, height: 170)))
    #expect(bandy.error > out.error)
}

/// A picture nobody can continue: speckle. There is no direction to follow and
/// no colour to carry, so whatever is invented below it is invention.
///
/// A diagonal was the first choice here and stopped being a good one — once the
/// fill started following the direction a boundary was already travelling, a
/// straight diagonal became one of the cases it gets exactly right. That is the
/// feature improving, so the test needs a harder picture rather than a lower
/// bar.
private func speckle(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var seed: UInt64 = 99
    func next() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double((seed >> 33) % 1000) / 1000.0
    }
    for y in 0..<h {
        for x in 0..<w {
            ctx.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return ctx.makeImage()!
}

private func diagonal(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1))
    ctx.move(to: CGPoint(x: 0, y: 0))
    ctx.addLine(to: CGPoint(x: w, y: h))
    ctx.addLine(to: CGPoint(x: w, y: 0))
    ctx.closePath()
    ctx.fillPath()
    return ctx.makeImage()!
}

@Test func aPictureNobodyCanContinueIsNotTrusted() throws {
    // The grade earns its keep by being sceptical here, and it has to be, or
    // the offer to spend money on the model never appears when it should.
    let out = try #require(Extend.grow(speckle(90, 90), toCover: CGRect(x: 0, y: 0, width: 90, height: 140)))
    #expect(!out.isTrusted, "speckle should not grade as trusted, scored \(out.error)")

    let flat = try #require(Extend.grow(solid(120, 120), toCover: CGRect(x: 0, y: 0, width: 120, height: 180)))
    #expect(flat.isTrusted, "flat artwork should still be trusted, scored \(flat.error)")
    #expect(out.error > Heal.trusted * 2, "speckle should score well past the line, got \(out.error)")
}

@Test func aStraightDiagonalIsFollowedRatherThanStreaked() throws {
    // What the first version could not do. Carried straight down, an edge
    // leaving the frame on a slant became a vertical column; followed, it
    // continues on its way and reproduces a held-out strip almost exactly.
    let out = try #require(Extend.grow(diagonal(120, 120), toCover: CGRect(x: 0, y: 0, width: 120, height: 180)))
    #expect(out.isTrusted, "a straight slant should be continued, scored \(out.error)")
}

/// What a service hands back: fully opaque, everywhere, including where the
/// artwork it was sent had nothing at all.
private func opaqueReply(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.11, green: 0.60, blue: 0.40, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

/// A cut-out: something on the right, nothing on the left.
private func halfCutOut(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.83, green: 0.38, blue: 0.16, alpha: 1))
    ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
    return ctx.makeImage()!
}

@Test func theModelsAnswerCannotFillInWhatWasSeeThrough() throws {
    let base = halfCutOut(80, 80)
    let merged = try #require(Extend.merge(model: opaqueReply(80, 80), into: base,
                                           region: CGRect(x: 0, y: 0, width: 80, height: 80)))

    // The whole complaint in one assertion: a reply that is opaque everywhere
    // must not turn the empty half of a cut-out into a black box.
    let empty = pixel(merged, 10, 40)
    #expect(empty == (0, 0, 0), "the see-through half came back as \(empty)")

    // And where there WAS artwork, the colour is the model's.
    let filled = pixel(merged, 70, 40)
    #expect(filled.1 > filled.0, "expected the model's green, got \(filled)")
}

@Test func aReplyOfTheWrongSizeDoesNotShiftThePicture() throws {
    let base = halfCutOut(80, 80)
    // A service that rounds its output to a different size used to slide the
    // whole picture sideways under a frame that had not moved.
    let merged = try #require(Extend.merge(model: opaqueReply(73, 91), into: base,
                                           region: CGRect(x: 40, y: 0, width: 40, height: 80)))
    #expect(merged.width == 80 && merged.height == 80)

    // The half that was never sent for redrawing is untouched.
    #expect(pixel(merged, 10, 40) == (0, 0, 0))
}
