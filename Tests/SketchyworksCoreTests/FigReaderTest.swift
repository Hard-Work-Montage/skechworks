import CoreGraphics
import Foundation
import Testing
@testable import SketchyworksCore

// Figma's path encoding: a command byte, then that command's points as
// little-endian float pairs.
//
// This is the one part of reading a .fig that the schema does NOT describe —
// it says "here are some bytes" and stops — so it was read off real files and
// is the piece that can go stale. These are the bytes that proved it: a
// rectangle whose lines land exactly on its own stated size, and an ellipse
// whose curves come back a circle.

private func bytes(_ parts: [Any]) -> Data {
    var d = Data()
    for p in parts {
        if let b = p as? UInt8 { d.append(b) }
        if let f = p as? Double {
            var bits = Float(f).bitPattern
            for _ in 0..<4 { d.append(UInt8(bits & 0xff)); bits >>= 8 }
        }
    }
    return d
}

@Test func aRectangleComesBackTheSizeItSaysItIs() throws {
    // Straight from Adam's file: 'Rectangle 1', stated size 310x278.
    let d = bytes([UInt8(1), 0.0, 0.0,
                   UInt8(2), 310.0, 0.0,
                   UInt8(2), 310.0, 278.0,
                   UInt8(2), 0.0, 278.0,
                   UInt8(5)])
    let p = try #require(FigReader.path(from: d))
    let box = p.boundingBoxOfPath
    #expect(box.width == 310)
    #expect(box.height == 278)
}

@Test func curvesAreReadAsCurvesAndNotAsCorners() throws {
    // A quarter of the ellipse in that file: command 4 takes SIX floats, two
    // controls and an end. Read as two, every curve in every file is wrong.
    let d = bytes([UInt8(1), 319.0, 159.5,
                   UInt8(4), 319.0, 247.6, 247.6, 319.0, 159.5, 319.0])
    let p = try #require(FigReader.path(from: d))
    let box = p.boundingBoxOfPath
    #expect(box.maxX == 319)
    #expect(box.maxY == 319)
    #expect(box.width > 100, "a curve read as a line would collapse this")
}

@Test func anUnknownCommandStopsRatherThanReadingRubbish() throws {
    // Nothing says how many numbers belong to a command, so an unfamiliar one
    // can't be skipped — carrying on would take whatever follows as coordinates.
    let d = bytes([UInt8(1), 0.0, 0.0, UInt8(2), 100.0, 100.0, UInt8(99), 7.0, 7.0])
    let p = try #require(FigReader.path(from: d))
    #expect(p.boundingBoxOfPath.maxX == 100, "it kept reading past a command it didn't know")
}

@Test func aTruncatedBlobKeepsWhatItHad() throws {
    let d = bytes([UInt8(1), 10.0, 10.0, UInt8(2), 90.0, 90.0, UInt8(2), 5.0])  // ends mid-point
    let p = try #require(FigReader.path(from: d))
    #expect(p.boundingBoxOfPath.maxX == 90)
}

@Test func nothingUsableComesBackAsNothing() {
    #expect(FigReader.path(from: Data()) == nil)
    #expect(FigReader.path(from: Data([9, 9, 9])) == nil)
}
