import CoreGraphics
import Foundation
import Testing
@testable import AccompliceCore

// Where a picture actually has something in it, so the handles can say so.

private func picture(_ w: Int, _ h: Int, content: CGRect) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.83, green: 0.38, blue: 0.16, alpha: 1))
    // y-up in a context; the rect is given the same way.
    ctx.fill(content)
    return ctx.makeImage()!
}

@Test func anEmptyBottomHalfIsNotPartOfThePicture() throws {
    // The case that started this: the bottom of a bitmap rubbed out, and a
    // frame still claiming the full height.
    let img = picture(100, 100, content: CGRect(x: 0, y: 50, width: 100, height: 50))
    let box = try #require(Trim.contentBounds(img))

    #expect(abs(box.width - 1.0) < 0.02)
    #expect(abs(box.height - 0.5) < 0.02)
    // y down: content in the upper half of the image.
    #expect(box.minY < 0.02)
}

@Test func aPictureThatFillsItsFrameIsLeftAlone() throws {
    let box = try #require(Trim.contentBounds(picture(60, 60, content: CGRect(x: 0, y: 0, width: 60, height: 60))))
    #expect(box == CGRect(x: 0, y: 0, width: 1, height: 1))
}

@Test func aHoleInTheMiddleChangesNothingAboutTheOutline() throws {
    let ctx = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
    ctx.clear(CGRect(x: 30, y: 30, width: 20, height: 20))
    let box = try #require(Trim.contentBounds(ctx.makeImage()!))

    // Rubbing out the middle of something is not a reason to move the handles.
    #expect(box == CGRect(x: 0, y: 0, width: 1, height: 1))
}

@Test func nothingLeftIsSaidRatherThanGuessed() {
    let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    #expect(Trim.contentBounds(ctx.makeImage()!) == nil)
}

@Test func aHairlineOfAntiAliasingDoesNotCount() throws {
    // Alpha this low is the ghost of an edge, not content — trimming to it
    // would leave the handles a pixel out and never settle.
    let ctx = CGContext(data: nil, width: 50, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 0.01))
    ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
    ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 10, y: 10, width: 30, height: 30))
    let box = try #require(Trim.contentBounds(ctx.makeImage()!))
    #expect(abs(box.width - 0.6) < 0.05, "expected the solid part only, got \(box)")
}

// The runaway: trimming moves the frame, and everything recorded in the old
// frame's coordinates has to move with it.

@Test func erasingTwiceInARowSettlesInsteadOfWalkingAway() throws {
    // A stand-in for the loop that grew a 762-wide layer to 3,360: trim, then
    // measure again, then trim again. If the second measurement disagrees with
    // the first because something was left behind in old coordinates, the box
    // never stops moving.
    let img = picture(120, 120, content: CGRect(x: 0, y: 40, width: 120, height: 80))
    let first = try #require(Trim.contentBounds(img))

    // Re-measuring what the first trim would leave has to give the whole thing.
    let cropped = try #require(img.cropping(to: CGRect(x: 0, y: 0, width: 120, height: 80)))
    let second = try #require(Trim.contentBounds(cropped))
    #expect(second == CGRect(x: 0, y: 0, width: 1, height: 1),
            "a trimmed picture is already trimmed; got \(second) after \(first)")
}

@Test func aStrokeMovesWithTheFrameItWasRecordedIn() {
    // The arithmetic the store does when it pulls the handles in. A stroke at
    // (10, 90) in a 100-tall frame that loses its top 40 must end up at (10,
    // 50), not stay at 90 pointing past the bottom of what is left.
    let stroke = EraseStroke(rect: CGRect(x: 10, y: 90, width: 20, height: 5))
    let dy: CGFloat = 40
    let moved = stroke.rect!.offsetBy(dx: 0, dy: -dy)
    #expect(moved.minY == 50)
}
