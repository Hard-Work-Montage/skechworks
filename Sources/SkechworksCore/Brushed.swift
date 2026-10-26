import CoreGraphics
import Foundation

/// Brushed metal: the streaks laid over a fill so a flat gray reads as metal.
///
/// Adam, 2026-10-26: color coins get printed metal instead of working around
/// the real metal, and a flat gray looked like paint. The look was tried as a
/// one-off on the Jerry coin first; straight streaks at 45° won over a spun,
/// circular finish. So there is one brushed look, not a menu of them.
///
/// The streaks are a tile of light and dark lines, drawn over the fill's own
/// color, so any fill color can be brushed and stays the color it was picked
/// as. The tile is anchored to the page rather than to the shape: two shapes
/// side by side carry one continuous set of streaks, the way one sheet of
/// metal would. Broad bands of shine run through it too, once per tile.
///
/// It is made from a fixed seed, so a file looks the same every time it opens
/// and on every machine that opens it.
public enum Brushed {
    /// Page units per tile side. One tile pixel per unit: a 1,640-unit coin
    /// prints at over 1,000 dpi on a 38 mm blank, which is plenty.
    public static let tileSize = 512
    /// Up and to the right, in page space where y runs down.
    public static let angle: CGFloat = -.pi / 4

    /// The tile, white and black at partial alpha so it lightens and darkens
    /// whatever is under it.
    public static let tile: CGImage? = makeTile()

    /// The tile as a PNG, for SVG export.
    public static let tilePNG: Data? = tile.flatMap { Renderer.png($0) }

    /// Streaks over `path`, which has already been filled.
    static func draw(over path: CGPath, opacity: CGFloat, in ctx: CGContext) {
        guard let tile, opacity > 0 else { return }
        let box = path.boundingBoxOfPath
        guard !box.isNull, !box.isEmpty else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setAlpha(opacity)
        ctx.rotate(by: angle)
        // CoreGraphics draws an image bottom-up. Flipping it keeps the tile the
        // same way round as the SVG pattern, which does not.
        ctx.scaleBy(x: 1, y: -1)
        let s = CGFloat(tileSize)
        ctx.draw(tile, in: CGRect(x: 0, y: 0, width: s, height: s), byTiling: true)
        ctx.restoreGState()
    }

    static func makeTile() -> CGImage? {
        let n = tileSize
        var rng = SplitMix(seed: 0x6D65_7461_6C21)
        func noise() -> [Float] { (0..<(n * n)).map { _ in rng.gaussian() } }
        // Long streaks plus a finer grain, both running along x.
        let long = normalized(streaks(noise(), n: n, sigma: 30))
        let fine = normalized(streaks(noise(), n: n, sigma: 6))
        var rgba = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            // Shine: broad bands across the streaks, periodic so the tile repeats.
            let v = Float(y) / Float(n) * 2 * .pi
            let shine = 0.10 * cos(v) + 0.05 * cos(3 * v + 1)
            for x in 0..<n {
                let i = y * n + x
                let d = 0.066 * long[i] + 0.044 * fine[i] + shine
                let a = min(0.6, abs(d) * 1.2)
                let level: UInt8 = d > 0 ? 255 : 0
                let alpha = UInt8((a * 255).rounded())
                // Premultiplied.
                let c = level == 255 ? alpha : 0
                rgba[i * 4] = c; rgba[i * 4 + 1] = c; rgba[i * 4 + 2] = c; rgba[i * 4 + 3] = alpha
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Blurred hard along x (three box passes, close to a Gaussian) and barely
    /// along y, wrapping both ways so the tile has no seam.
    private static func streaks(_ src: [Float], n: Int, sigma: Float) -> [Float] {
        var a = src
        let r = max(1, Int(((sqrt(12 * sigma * sigma / 3 + 1)) / 2).rounded()))
        var row = [Float](repeating: 0, count: n)
        for _ in 0..<3 {
            for y in 0..<n {
                let base = y * n
                var sum: Float = 0
                for k in -r...r { sum += a[base + ((k % n) + n) % n] }
                for x in 0..<n {
                    row[x] = sum / Float(2 * r + 1)
                    sum += a[base + (x + r + 1) % n] - a[base + ((x - r) % n + n) % n]
                }
                for x in 0..<n { a[base + x] = row[x] }
            }
        }
        var out = a
        for y in 0..<n {
            let up = ((y - 1 + n) % n) * n, dn = ((y + 1) % n) * n, me = y * n
            for x in 0..<n { out[me + x] = 0.25 * a[up + x] + 0.5 * a[me + x] + 0.25 * a[dn + x] }
        }
        return out
    }

    private static func normalized(_ a: [Float]) -> [Float] {
        let mean = a.reduce(0, +) / Float(a.count)
        let sd = sqrt(a.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(a.count))
        return sd > 0 ? a.map { ($0 - mean) / sd } : a
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
        mutating func gaussian() -> Float {
            let u = max(unit(), 1e-7), v = unit()
            return sqrt(-2 * log(u)) * cos(2 * .pi * v)
        }
    }
}
