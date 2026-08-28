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
    /// Where the marks actually sit, as fractions of the picture.
    public let inkBounds: CGRect
    /// How much ink is in each cell of a 24×24 grid, 0 to 9, row 0 at the top.
    ///
    /// The antidote to a model estimating positions off a picture, which is the one
    /// thing it is reliably bad at. Told where the marks are, it can put them there
    /// instead of guessing — the same reasoning as handing over the palette rather
    /// than asking it to read colours off pixels.
    public let inkGrid: [[Int]]
    /// How thick the lines are, as a fraction of the picture's side. 0 when
    /// there's no ink.
    ///
    /// The prompt asks for a strokeWidth on every path and nothing here used to
    /// measure one, so the model picked a number by eye. That single guess
    /// caps the score on its own: with the geometry exactly right, drawing a
    /// 14px line at 24px scores 65% and at 32px scores 50%, and the loop then
    /// spends its remaining passes moving shapes that were never in the wrong
    /// place. Same reasoning as handing over the palette instead of asking it
    /// to read colours off pixels.
    public let strokeWidth: Double
    public let verdict: Verdict

    public static func == (a: ImageStats, b: ImageStats) -> Bool {
        a.uniqueColors == b.uniqueColors && a.verdict == b.verdict
            && a.palette.map(\.hex) == b.palette.map(\.hex)
    }

    /// Reads the picture at a small fixed size. Detail below this doesn't change
    /// what KIND of image it is, and it keeps the whole thing under a millisecond.
    /// 144 rather than a round 128 so the 24×24 ink grid divides it exactly. An
    /// uneven split leaves the last row and column covering more pixels than the
    /// rest while being averaged as if they didn't, which reads as a solid edge
    /// down two sides of every picture.
    public static func measure(_ image: CGImage, samples: Int = 144) -> ImageStats {
        let side = max(16, samples)
        guard let pixels = flatten(image, side: side) else {
            return ImageStats(uniqueColors: 0, dominantCoverage: 0, flatShare: 0,
                              edgeDensity: 0, palette: [], inkBounds: .zero, inkGrid: [],
                              strokeWidth: 0, verdict: .photographic)
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
        // Two-tone is a share, not a count. Counting distinct colours calls a
        // drawing line art at one sample size and something else at the next,
        // because antialiasing invents a different handful of greys each time.
        let twoTone = ranked.prefix(2).reduce(0.0) { $0 + Double($1.value) / total }
        // A colour earns its keep by holding a real area, not by appearing. Sum
        // those and you have the share of the picture that is solid.
        let flat = exact.values.filter { Double($0) / total >= 0.005 }
                               .reduce(0.0) { $0 + Double($1) / total }

        let palette = significant.prefix(12).map { entry -> (hex: String, share: Double) in
            let r = (entry.key >> 8 & 0xF) * 17, g = (entry.key >> 4 & 0xF) * 17, b = (entry.key & 0xF) * 17
            return (String(format: "#%02X%02X%02X", r, g, b), Double(entry.value) / total)
        }

        // Ink is anything that isn't the background, and the background is whatever
        // the picture is mostly made of — so this reads white-on-black as happily as
        // black-on-white.
        let bgKey = ranked.first?.key ?? 0
        let bgr = (bgKey >> 8 & 0xF) * 17, bgg = (bgKey >> 4 & 0xF) * 17, bgb = (bgKey & 0xF) * 17
        func inked(_ i: Int) -> Bool {
            max(abs(Int(pixels[i]) - bgr), abs(Int(pixels[i + 1]) - bgg),
                abs(Int(pixels[i + 2]) - bgb)) > 48
        }
        let cells = 24
        let step = max(1, side / cells)
        var grid = Array(repeating: Array(repeating: 0, count: cells), count: cells)
        var minX = side, minY = side, maxX = 0, maxY = 0, inkCount = 0
        for y in 0..<side {
            for x in 0..<side where inked((y * side + x) * 4) {
                inkCount += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                let r = min(cells - 1, y / step), c = min(cells - 1, x / step)
                grid[r][c] += 1
            }
        }
        let per = Double(step * step)
        for r in 0..<cells {
            for c in 0..<cells {
                grid[r][c] = min(9, Int((Double(grid[r][c]) / per * 9).rounded()))
            }
        }
        let bounds = inkCount == 0 ? CGRect.zero
            : CGRect(x: Double(minX) / Double(side), y: Double(minY) / Double(side),
                     width: Double(maxX - minX + 1) / Double(side),
                     height: Double(maxY - minY + 1) / Double(side))

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
        } else if twoTone > 0.85 {
            verdict = .lineArt
        } else if unique <= 16 && coverage > 0.7 {
            verdict = .flat
        } else {
            verdict = .detailed
        }

        // Measured off a finer copy than the rest of this: at 144 samples a
        // typical line is only a few pixels wide, and rounding to the nearest
        // one is a 20% error in the number the model is about to be handed.
        let thickness = strokeWidth(of: image, background: (bgr, bgg, bgb))

        return ImageStats(uniqueColors: unique, dominantCoverage: coverage, flatShare: flat,
                          edgeDensity: density, palette: Array(palette),
                          inkBounds: bounds, inkGrid: grid, strokeWidth: thickness,
                          verdict: verdict)
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
        the marks sit inside x \(pct(inkBounds.minX))-\(pct(inkBounds.maxX)), \
        y \(pct(inkBounds.minY))-\(pct(inkBounds.maxY)) of the area
        where the marks are, 24×24 over the whole area, 0 empty and 9 solid, \
        row 1 at the TOP:
        \(inkGrid.map { $0.map(String.init).joined() }.joined(separator: "\n        "))
        """
    }

    private func pct(_ v: CGFloat) -> String { "\(Int((v * 100).rounded()))%" }

    /// The typical thickness of a line, in the coordinates the drawing will use.
    ///
    /// Given as a number to put in strokeWidth rather than a fraction to convert,
    /// because the conversion is arithmetic done badly under load.
    public func strokeWidthHint(for size: CGSize) -> String? {
        guard strokeWidth > 0 else { return nil }
        let px = strokeWidth * Double(min(size.width, size.height))
        guard px >= 1 else { return nil }
        return "the lines are about \(Int(px.rounded())) thick — use that as strokeWidth "
             + "unless a part is visibly heavier or lighter than the rest"
    }

    /// Median thickness of the ink, as a fraction of the picture's side.
    ///
    /// For every inked pixel, the shorter of the horizontal and vertical runs it
    /// sits in. Down the length of a stroke that shorter run IS the stroke's
    /// width, whichever way the stroke happens to run; the median then shrugs off
    /// corners and joins, where both runs are short, and filled regions, where
    /// both are long.
    static func strokeWidth(of image: CGImage, background: (Int, Int, Int),
                            samples: Int = 288) -> Double {
        let side = max(32, samples)
        guard let pixels = flatten(image, side: side) else { return 0 }
        let (br, bg, bb) = background
        func inked(_ x: Int, _ y: Int) -> Bool {
            let i = (y * side + x) * 4
            return max(abs(Int(pixels[i]) - br), abs(Int(pixels[i + 1]) - bg),
                       abs(Int(pixels[i + 2]) - bb)) > 48
        }

        // Four directions, not two. Across a stroke running at 45°, both the
        // horizontal and the vertical crossing are √2 times its real width, so
        // measuring on the axes alone reads a diagonal as half again as thick
        // as it is — and a drawn hand is nearly all diagonals and curves. The
        // two diagonal scans put a near-perpendicular crossing within 22.5° of
        // any stroke, whichever way it runs, which caps the overshoot at 8%.
        // A diagonal step covers √2 pixels, so those runs are scaled to match.
        let directions: [(dx: Int, dy: Int, scale: Double)] = [
            (1, 0, 1), (0, 1, 1), (1, 1, 2.0.squareRoot()), (1, -1, 2.0.squareRoot()),
        ]
        var best = [Double](repeating: .greatestFiniteMagnitude, count: side * side)
        var isInk = [Bool](repeating: false, count: side * side)
        for y in 0..<side {
            for x in 0..<side { isInk[y * side + x] = inked(x, y) }
        }

        for (dx, dy, scale) in directions {
            for start in 0..<(side * side) {
                let sx = start % side, sy = start / side
                guard isInk[start] else { continue }
                // Only walk from the first pixel of a run, or every pixel would
                // re-measure the tail of the run it sits in.
                let px = sx - dx, py = sy - dy
                if px >= 0, px < side, py >= 0, py < side, isInk[py * side + px] { continue }

                var run: [Int] = []
                var x = sx, y = sy
                while x >= 0, x < side, y >= 0, y < side, isInk[y * side + x] {
                    run.append(y * side + x)
                    x += dx; y += dy
                }
                let length = Double(run.count) * scale
                for i in run where length < best[i] { best[i] = length }
            }
        }

        var widths = best.enumerated().compactMap { index, value in
            isInk[index] && value < .greatestFiniteMagnitude ? value : nil
        }
        guard !widths.isEmpty else { return 0 }
        widths.sort()
        return widths[widths.count / 2] / Double(side)
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
