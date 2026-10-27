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
/// metal would. A broad band of shine runs across them too, on its own strip
/// so it doesn't repeat with the tile.
///
/// It is made from a fixed seed, so a file looks the same every time it opens
/// and on every machine that opens it.
public enum Brushed {
    /// Page units per tile side.
    public static let tileSize = 512
    /// Two tile pixels per unit. At one per unit the streaks came out twice
    /// as wide as the one-off Adam picked and read as scratches (10-26).
    public static let tilePixels = 1024
    /// Page units from one shine band to the next: about one broad band across
    /// a coin, the way the one-off had it. Repeating it every tile made stripes.
    public static let shinePeriod = 3072
    /// Up and to the right, in page space where y runs down.
    public static let angle: CGFloat = -.pi / 4

    /// The streaks and the shine are each a gain: how much brighter or darker
    /// to make whatever is under them, in proportion, the way the one-off
    /// scaled the gray. An overlay of white at partial alpha lightened dark
    /// grays far more than light ones and made the trees flare (10-26), so
    /// the gain goes on as two passes: a multiply that darkens and a color
    /// dodge that lightens, each by the same fraction on any color.
    public struct Gain: @unchecked Sendable {
        public let darken: CGImage
        public let lighten: CGImage
        public let darkenPNG: Data?
        public let lightenPNG: Data?
        /// Its size in page units.
        public let size: CGSize
        public let id: String

        init?(gain: [Float], width: Int, height: Int, size: CGSize, id: String) {
            var dk = [UInt8](repeating: 255, count: gain.count), lt = [UInt8](repeating: 0, count: gain.count)
            for (i, g0) in gain.enumerated() {
                let g = max(-0.6, min(0.6, g0))
                // multiply by 1 + g; dodge divides by 1 - s, so s = g / (1 + g).
                if g < 0 { dk[i] = UInt8(((1 + g) * 255).rounded()) } else { lt[i] = UInt8((g / (1 + g) * 255).rounded()) }
            }
            guard let d = Brushed.grayImage(dk, width: width, height: height),
                  let l = Brushed.grayImage(lt, width: width, height: height) else { return nil }
            darken = d; lighten = l
            darkenPNG = Renderer.png(d); lightenPNG = Renderer.png(l)
            self.size = size; self.id = id
        }
    }

    public static let streaks: Gain? = makeStreaks()
    public static let shine: Gain? = makeShine()
    static let shineWidth = 16

    /// Streaks over `path`, which has already been filled.
    static func draw(over path: CGPath, opacity: CGFloat, in ctx: CGContext) {
        guard let streaks, let shine, opacity > 0 else { return }
        let box = path.boundingBoxOfPath
        guard !box.isNull, !box.isEmpty else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setAlpha(opacity)
        // Zoomed out, plain sampling of the fine tile turns the streaks to grit.
        ctx.interpolationQuality = .high
        ctx.rotate(by: angle)
        // CoreGraphics draws an image bottom-up. Flipping it keeps the tile the
        // same way round as the SVG pattern, which does not.
        ctx.scaleBy(x: 1, y: -1)
        for gain in [streaks, shine] {
            let r = CGRect(origin: .zero, size: gain.size)
            ctx.setBlendMode(.multiply)
            ctx.draw(gain.darken, in: r, byTiling: true)
            ctx.setBlendMode(.colorDodge)
            ctx.draw(gain.lighten, in: r, byTiling: true)
        }
        ctx.restoreGState()
    }

    fileprivate static func grayImage(_ g: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(g) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) ?? CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func makeStreaks() -> Gain? {
        let n = tilePixels
        var rng = SplitMix(seed: 0x6D65_7461_6C21)
        func noise() -> [Float] { (0..<(n * n)).map { _ in rng.gaussian() } }
        // Long streaks plus a finer grain, both running along x, in tile pixels.
        let long = normalized(blurred(noise(), n: n, sigma: 60, across: 0.6))
        let fine = normalized(blurred(noise(), n: n, sigma: 12, across: 0.4))
        // The one-off: gray × (1 + 0.07t) + 8t, which on #AAAAAA is 11.7% per t.
        let gain = (0..<(n * n)).map { 0.117 * (0.6 * long[$0] + 0.4 * fine[$0]) }
        let s = CGFloat(tileSize)
        return Gain(gain: gain, width: n, height: n, size: CGSize(width: s, height: s), id: "brushed")
    }

    static func makeShine() -> Gain? {
        let w = shineWidth, h = shinePeriod
        var gain = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let v = Float(y) / Float(h) * 2 * .pi
            let g = 0.10 * cos(v) + 0.06 * cos(3 * v + 1)
            for x in 0..<w { gain[y * w + x] = g }
        }
        return Gain(gain: gain, width: w, height: h, size: CGSize(width: w, height: h), id: "brushed-shine")
    }

    /// Blurred hard along x (three box passes, close to a Gaussian) and by
    /// `across` along y, wrapping both ways so the tile has no seam.
    private static func blurred(_ src: [Float], n: Int, sigma: Float, across: Float) -> [Float] {
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
        let side = exp(-1 / (2 * across * across)), mid = 1 / (1 + 2 * side), edge = side * mid
        var out = a
        for y in 0..<n {
            let up = ((y - 1 + n) % n) * n, dn = ((y + 1) % n) * n, me = y * n
            for x in 0..<n { out[me + x] = edge * a[up + x] + mid * a[me + x] + edge * a[dn + x] }
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
