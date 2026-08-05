import CoreGraphics
import Foundation

/// What kind of picture this is, measured rather than guessed.
///
/// Two jobs, both of which a model would do worse and slower. It decides whether an
/// image is worth tracing at all, and it hands over the palette so the colours are
/// told rather than eyeballed — a model reading hex off a photograph is a coin flip,
/// and counting pixels is not.
///
/// It also answers the question a text-only router can't: on-device models take no
/// images, so "is this traceable" has to be arithmetic if it's going to be free.
public struct ImageStats: Sendable, Equatable {

    public enum Verdict: String, Sendable {
        /// Two tones and hard edges. An outline drawing, and the one case where the
        /// elegant answer is strokes rather than filled regions.
        case lineArt
        /// A handful of flat colours. Logos, icons, comic art — reconstructable.
        case flat
        /// Flat-ish but busy. Worth tracing, not worth rebuilding by hand.
        case detailed
        /// Continuous tone. Nothing here is a shape, and pretending otherwise
        /// produces a thousand paths nobody can edit.
        case photographic

        public var traceable: Bool { self != .photographic }
    }

    /// Colours holding at least a noticeable share of the picture. Antialiasing
    /// invents thousands of one-off shades, and counting those calls every drawing
    /// a photograph.
    public let uniqueColors: Int
    /// The share of the image held by its four commonest colours.
    public let dominantCoverage: Double
    /// How much of the picture is solid areas of one exact colour.
    ///
    /// The measurement that actually separates a drawing from a photograph, and it
    /// took a wrong answer to find it. Counting colours doesn't: a two-colour
    /// gradient quantises to few enough buckets to look like a logo. But flat art
    /// is mostly interiors — big regions of one exact value — and continuous tone
    /// has none at all, because every pixel differs slightly from its neighbour.
    public let flatShare: Double
    /// Roughly, the fraction of pixels sitting on an edge.
    public let edgeDensity: Double
    /// Commonest colours first, as hex, with the share each covers.
    public let palette: [(hex: String, share: Double)]
    public let verdict: Verdict

    public static func == (a: ImageStats, b: ImageStats) -> Bool {
        a.uniqueColors == b.uniqueColors && a.verdict == b.verdict
            && a.palette.map(\.hex) == b.palette.map(\.hex)
    }

    /// Reads the picture at a small fixed size. Detail below this doesn't change
    /// what KIND of image it is, and it keeps the whole thing under a millisecond.
    public static func measure(_ image: CGImage, samples: Int = 128) -> ImageStats {
        let side = max(16, samples)
        guard let pixels = flatten(image, side: side) else {
            return ImageStats(uniqueColors: 0, dominantCoverage: 0, flatShare: 0,
                              edgeDensity: 0, palette: [], verdict: .photographic)
        }

        // Four bits a channel. Fine enough to keep colours a person would call
        // different apart, coarse enough that a gradient doesn't become a thousand.
        var counts: [Int: Int] = [:]
        var exact: [Int: Int] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            counts[(r >> 4) << 8 | (g >> 4) << 4 | (b >> 4), default: 0] += 1
            exact[r << 16 | g << 8 | b, default: 0] += 1
        }
        let total = Double(side * side)
        let ranked = counts.sorted { $0.value > $1.value }
        let significant = ranked.filter { Double($0.value) / total >= 0.002 }
        let coverage = ranked.prefix(4).reduce(0.0) { $0 + Double($1.value) / total }
        // A colour earns its keep by holding a real area, not by appearing. Sum
        // those and you have the share of the picture that is solid.
        let flat = exact.values.filter { Double($0) / total >= 0.005 }
                               .reduce(0.0) { $0 + Double($1) / total }

        let palette = significant.prefix(12).map { entry -> (hex: String, share: Double) in
            let r = (entry.key >> 8 & 0xF) * 17, g = (entry.key >> 4 & 0xF) * 17, b = (entry.key & 0xF) * 17
            return (String(format: "#%02X%02X%02X", r, g, b), Double(entry.value) / total)
        }

        var edges = 0
        for y in 0..<(side - 1) {
            for x in 0..<(side - 1) {
                let i = (y * side + x) * 4
                let right = i + 4, below = i + side * 4
                let dx = abs(Int(pixels[i]) - Int(pixels[right])) + abs(Int(pixels[i + 1]) - Int(pixels[right + 1]))
                let dy = abs(Int(pixels[i]) - Int(pixels[below])) + abs(Int(pixels[i + 1]) - Int(pixels[below + 1]))
                if max(dx, dy) > 48 { edges += 1 }
            }
        }
        let density = Double(edges) / total

        let unique = significant.count
        let verdict: Verdict
        if flat < 0.5 {
            // Nothing here holds still long enough to be a shape.
            verdict = .photographic
        } else if unique <= 3 && coverage > 0.9 {
            verdict = .lineArt
        } else if unique <= 16 && coverage > 0.7 {
            verdict = .flat
        } else {
            verdict = .detailed
        }

        return ImageStats(uniqueColors: unique, dominantCoverage: coverage, flatShare: flat,
                          edgeDensity: density, palette: Array(palette), verdict: verdict)
    }

    /// The measurements as the model should be told them.
    ///
    /// Facts it would otherwise have to estimate off a picture, which is the one
    /// thing it's reliably bad at.
    public var summary: String {
        let colours = palette.map { "\($0.hex) \(Int(($0.share * 100).rounded()))%" }.joined(separator: ", ")
        return """
        picture: \(verdict.rawValue), \(uniqueColors) significant colours, \
        \(Int((flatShare * 100).rounded()))% of it solid areas, \
        \(Int((edgeDensity * 100).rounded()))% of it on an edge
        palette, commonest first: \(colours)
        """
    }

    private static func flatten(_ image: CGImage, side: Int) -> [UInt8]? {
        let bytesPerRow = side * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * side)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // On white, so a transparent PNG of black line art reads as black on
            // white rather than as one colour and a lot of nothing.
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? buffer : nil
    }
}
