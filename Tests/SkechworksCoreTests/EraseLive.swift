import Testing
import CoreGraphics
import Foundation
@testable import SkechworksCore

private func pixels(_ image: CGImage) -> [UInt8] {
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self),
                                     count: image.width * image.height))
}

@Test(arguments: [CGFloat(0), 0.5])
func aStrokeDrawnAFewPointsAFrameMatchesOneDrawnInOneGo(softness: CGFloat) throws {
    // The canvas asks for the mask on every frame of a drag, a point longer
    // each time. Built up that way it has to come out exactly as it would
    // if the finished stroke were drawn from nothing.
    let size = CGSize(width: 160 + softness, height: 120)
    let earlier = EraseStroke(rect: CGRect(x: 4, y: 4, width: 20, height: 10))
    let path = (0..<40).map { CGPoint(x: 10 + CGFloat($0) * 3.3, y: 60 + 30 * sin(CGFloat($0) / 5)) }

    var live: CGImage?
    for n in 1...path.count {
        live = EraseMask.image(strokes: [earlier, EraseStroke(points: Array(path[0..<n]), radius: 9, softness: softness)],
                               size: size)
    }

    let whole = try #require(EraseMask.context(size: size, scale: 2))
    EraseMask.stamp(earlier, in: whole)
    EraseMask.stamp(EraseStroke(points: path, radius: 9, softness: softness), in: whole)
    #expect(pixels(try #require(live)) == pixels(try #require(whole.makeImage())))
}

@Test func aChangedEarlierStrokeRebuildsTheMask() throws {
    let size = CGSize(width: 90, height: 90)
    let a = EraseStroke(points: [CGPoint(x: 20, y: 20), CGPoint(x: 70, y: 20)], radius: 6, softness: 0)
    _ = EraseMask.image(strokes: [a], size: size)
    // Undo took the stroke away and a different one went down in its place.
    let b = EraseStroke(points: [CGPoint(x: 20, y: 70), CGPoint(x: 70, y: 70)], radius: 6, softness: 0)
    let mask = try #require(EraseMask.image(strokes: [b], size: size))

    let whole = try #require(EraseMask.context(size: size, scale: 2))
    EraseMask.stamp(b, in: whole)
    #expect(pixels(mask) == pixels(try #require(whole.makeImage())))
}
