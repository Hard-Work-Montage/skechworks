import CoreGraphics
import Foundation

/// A colour picture turned into black ink on white, every line where it was.
///
/// The case this is for is a colour coin drawn as an engraving: inked
/// linework with paint laid over it. A model asked for the black and white
/// version draws the coin again and the lines come back nearly, never
/// exactly, where they were (Adam, 2026-10-21). This only decides, pixel by
/// pixel, which ones are ink.
///
/// Three tests, in order:
///
/// - A pixel is judged by its BRIGHTEST channel, not its grey. A saturated
///   red leaf or a yellow tree has one channel up high, so it reads light and
///   goes white. Only ink, dark in every channel, reads dark.
/// - A line is darker than what's round it. That keeps the hatching drawn
///   over a dark green pine, which a single cut-off would fill in solid.
/// - A big dark area (the banner behind lettering) is dark outright, judged
///   a little blurred so it fills solid instead of breaking up.
///
/// Specks smaller than a few pixels are dropped last: dust on a screenshot,
/// noise in a shadow.
///
/// Photoshop has no one command for it. Its Threshold is the single cut-off
/// on its own, and the usual recipe is a Black & White adjustment with the
/// colours pushed light, then High Pass, then Threshold, which is these three
/// tests done by hand.
public enum BlackAndWhite {

    /// How dark, of 255, an area has to be to fill solid. 90 suited the
    /// Adirondack chairs coin: a solid banner, open trees.
    public static let defaultSolid = 90.0

    /// Below this many pixels on the long side the picture is worked at twice
    /// its size, so the cut edges come out smooth rather than in steps.
    static let upscaleBelow = 2000

    /// The tuning was done on a picture this wide; the blurs and the speck
    /// size scale with the picture so a small one isn't over-blurred.
    static let referenceWidth = 2480.0

    public static func make(from image: CGImage, solid: Double = defaultSolid) -> CGImage? {
        let scale = max(image.width, image.height) < upscaleBelow ? 2 : 1
        let w = image.width * scale, h = image.height * scale
        guard w > 0, h > 0, var v = brightest(image, width: w, height: h) else { return nil }

        let s = Float(Double(w) / referenceWidth)
        v = blurred(v, w, h, sigma: max(0.5, 0.8 * s))
        let local = blurred(v, w, h, sigma: max(2, 9 * s))
        let soft = blurred(v, w, h, sigma: max(1, 3 * s))
        let cut = Float(solid)

        var ink = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            ink[i] = v[i] < local[i] - 12 || v[i] < 45 || soft[i] < cut
        }
        despeckle(&ink, w, h, minArea: max(4, Int((12 * s * s).rounded())))
        return render(ink, w, h)
    }

    /// Each pixel's brightest channel, 0...255. Clear pixels count as white:
    /// premultiplied, a clear pixel is (0,0,0,0) and would read as ink.
    static func brightest(_ image: CGImage, width w: Int, height h: Int) -> [Float]? {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var v = [Float](repeating: 255, count: w * h)
        for i in 0..<(w * h) {
            let a = Float(bytes[i * 4 + 3])
            guard a >= 128 else { continue }
            let m = Float(max(bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2]))
            v[i] = min(255, m * 255 / a)
        }
        return v
    }

    /// A Gaussian, near enough: three box blurs each way, or one 3×3 for a
    /// blur under a pixel and a bit, where three would already be too wide.
    static func blurred(_ src: [Float], _ w: Int, _ h: Int, sigma: Float) -> [Float] {
        let passes = sigma < 1.2 ? 1 : 3
        // n boxes of radius r spread by sigma² = n((2r+1)² - 1) / 12.
        let width = (12 * sigma * sigma / Float(passes) + 1).squareRoot()
        let r = max(1, Int(((width - 1) / 2).rounded()))
        var a = src, b = src
        for _ in 0..<passes {
            boxRows(a, &b, w, h, r)
            boxColumns(b, &a, w, h, r)
        }
        return a
    }

    /// A running mean across each row, the edge pixel repeated past the ends.
    private static func boxRows(_ src: [Float], _ dst: inout [Float], _ w: Int, _ h: Int, _ r: Int) {
        let n = Float(2 * r + 1)
        for y in 0..<h {
            let row = y * w
            var sum: Float = 0
            for k in -r...r { sum += src[row + min(max(k, 0), w - 1)] }
            for x in 0..<w {
                dst[row + x] = sum / n
                sum += src[row + min(x + r + 1, w - 1)] - src[row + max(x - r, 0)]
            }
        }
    }

    private static func boxColumns(_ src: [Float], _ dst: inout [Float], _ w: Int, _ h: Int, _ r: Int) {
        let n = Float(2 * r + 1)
        for x in 0..<w {
            var sum: Float = 0
            for k in -r...r { sum += src[min(max(k, 0), h - 1) * w + x] }
            for y in 0..<h {
                dst[y * w + x] = sum / n
                sum += src[min(y + r + 1, h - 1) * w + x] - src[max(y - r, 0) * w + x]
            }
        }
    }

    /// Clears every patch of ink smaller than `minArea`, eight-way connected.
    static func despeckle(_ ink: inout [Bool], _ w: Int, _ h: Int, minArea: Int) {
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = [], patch: [Int] = []
        for start in 0..<(w * h) where ink[start] && !seen[start] {
            stack.append(start)
            seen[start] = true
            patch.removeAll(keepingCapacity: true)
            while let i = stack.popLast() {
                patch.append(i)
                let x = i % w, y = i / w
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < h else { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0, nx < w else { continue }
                        let j = ny * w + nx
                        if ink[j] && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            if patch.count < minArea { for i in patch { ink[i] = false } }
        }
    }

    /// Opaque black on white.
    static func render(_ ink: [Bool], _ w: Int, _ h: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) where ink[i] {
            bytes[i * 4] = 0; bytes[i * 4 + 1] = 0; bytes[i * 4 + 2] = 0
        }
        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }
}
