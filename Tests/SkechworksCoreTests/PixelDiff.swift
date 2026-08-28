import Testing
import Foundation
import CoreGraphics
import ImageIO

/// Compares two rendered pages. Simplification that looks fine at thumbnail size can
/// still have moved an edge; this measures it.
@Test func pixelDiffPreview() throws {
    let env = ProcessInfo.processInfo.environment
    guard let one = env["DIFF_A"], let two = env["DIFF_B"] else { return }

    func load(_ path: String) -> (CGImage, [UInt8], Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h)
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (img, buf, w, h)
    }

    guard let (_, a, w, h) = load(one), let (_, b, w2, h2) = load(two) else {
        Issue.record("couldn't load"); return
    }
    guard w == w2, h == h2 else {
        print("DIFF sizes differ: \(w)x\(h) vs \(w2)x\(h2)"); return
    }
    var differing = 0
    for i in 0..<(w * h) where abs(Int(a[i]) - Int(b[i])) > 40 { differing += 1 }
    let pct = Double(differing) * 100 / Double(w * h)
    print(String(format: "DIFF %d of %d pixels differ (%.3f%%)", differing, w * h, pct))
}
