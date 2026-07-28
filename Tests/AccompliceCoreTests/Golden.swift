import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AccompliceCore

// Golden-image tests: render a scene and compare it against a committed reference.
//
// Unit tests say the numbers are right. They said the numbers were right while a
// dragged mask sat in the wrong place, because the wrongness was in how the pieces
// composed, not in any one of them. A picture catches that, and catches it without
// anyone having to think of the specific assertion first.
//
// Run with RECORD_GOLDENS=1 to write the references. Do that only after LOOKING at
// what changed — a recorded golden is a claim that the new output is correct.

enum Golden {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // AccompliceCoreTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Goldens")

    static var recording: Bool { ProcessInfo.processInfo.environment["RECORD_GOLDENS"] != nil }

    /// Grey samples for a rendered page, plus its size.
    static func pixels(_ image: CGImage) -> (data: [UInt8], width: Int, height: Int) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        ctx?.setFillColor(gray: 1, alpha: 1)
        ctx?.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (buf, w, h)
    }

    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// Renders `page` and compares it with the reference of the same name.
///
/// `tolerance` is the share of pixels allowed to differ, as a percentage. Anti-aliasing
/// moves a fraction of a percent between machines; a real change moves much more.
func expectGolden(_ name: String, page: Page, images: [String: Data] = [:],
                  maxDimension: CGFloat = 600, tolerance: Double = 0.35,
                  adjusting: Set<String> = [], live: CGAffineTransform = .identity,
                  sourceLocation: SourceLocation = #_sourceLocation) {
    guard let rendered = Renderer(images: images).render(page: page, maxDimension: maxDimension,
                                                        adjusting: adjusting, live: live),
          let png = Renderer.png(rendered) else {
        Issue.record("\(name): nothing rendered", sourceLocation: sourceLocation)
        return
    }
    let url = Golden.directory.appendingPathComponent("\(name).png")

    guard !Golden.recording, FileManager.default.fileExists(atPath: url.path) else {
        try? FileManager.default.createDirectory(at: Golden.directory, withIntermediateDirectories: true)
        try? png.write(to: url)
        Issue.record("\(name): reference recorded — look at it and commit it",
                     sourceLocation: sourceLocation)
        return
    }

    guard let reference = Golden.load(url) else {
        Issue.record("\(name): reference unreadable", sourceLocation: sourceLocation)
        return
    }
    let a = Golden.pixels(reference), b = Golden.pixels(rendered)
    guard a.width == b.width, a.height == b.height else {
        Issue.record("\(name): size changed, \(a.width)x\(a.height) → \(b.width)x\(b.height)",
                     sourceLocation: sourceLocation)
        return
    }
    var differing = 0
    for i in 0..<(a.width * a.height) where abs(Int(a.data[i]) - Int(b.data[i])) > 40 { differing += 1 }
    let share = Double(differing) * 100 / Double(a.width * a.height)
    if share > tolerance {
        // Leave the actual output beside the reference so the two can be compared.
        try? png.write(to: Golden.directory.appendingPathComponent("\(name).actual.png"))
        Issue.record("\(name): \(String(format: "%.2f", share))% of pixels differ (allowed \(tolerance)%) — see \(name).actual.png",
                     sourceLocation: sourceLocation)
    }
}
