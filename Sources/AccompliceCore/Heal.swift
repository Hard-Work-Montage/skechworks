import CoreGraphics
import Foundation

/// Filling a hole in a picture from what surrounds it, with no model and no
/// network.
///
/// Removing something is usually not a hard problem. Box the eye on a cartoon
/// squirrel and everything around the box is one flat red — there is nothing to
/// invent, only something to continue. Holding the rim of the hole fixed and
/// letting the inside settle to it reproduces exactly what was behind the eye,
/// in a few milliseconds, offline, for nothing. A diffusion model does the same
/// job in two minutes for forty cents and comes back a shade off.
///
/// Where this can't help is a real photograph: gravel, foliage, brickwork, a
/// crowd. Smooth colour into those and you get a blur where the thing was. So
/// the fill grades its own work before offering it — see `error`. Only when it
/// can't be trusted is a model worth asking for.
public enum Heal {

    /// A finished fill and how much to believe it.
    public struct Attempt {
        public let image: CGImage
        /// Average channel error, 0–255, measured on real pixels the fill was
        /// not allowed to see. Under `trusted` the result is indistinguishable
        /// from the artwork it continues.
        public let error: Double
        /// How varied the surroundings are, for explaining the verdict.
        public let spread: Double
        public var isTrusted: Bool { error < Heal.trusted }
    }

    /// Where "continues the picture" stops being true.
    ///
    /// Calibrated on real removals: a flat area scores 1–3, a soft gradient 4–8,
    /// and the moment a hard edge crosses the hole it jumps past 20. Ten leaves
    /// room for grain and shading without letting a smeared edge through.
    public static let trusted = 10.0

    /// Fills `box` (in pixels, y down from the top) from its surroundings.
    ///
    /// Returns nil only when the box is unusable — off the image, or so large
    /// there is no picture left to continue from.
    public static func fill(_ image: CGImage, box: CGRect) -> Attempt? {
        let clip = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let hole = box.integral.intersection(clip)
        // The hole has to leave some picture behind, but it does not have to
        // leave some on every side. A band running the full width of an image
        // still has the rows above and below it to continue from — and every
        // extension along an edge is exactly that shape, so requiring both
        // dimensions to be short refused the whole of Extend.
        guard hole.width >= 1, hole.height >= 1,
              hole.width < CGFloat(image.width) || hole.height < CGFloat(image.height),
              var canvas = Canvas(image) else { return nil }

        let box = IntRect(hole)

        // How far out to look, and how much of that to hide from the fill so it
        // can be marked on work it didn't see. Proportional to the hole: a big
        // hole needs a wide rim before the surroundings mean anything.
        let band = min(12, max(3, min(box.w, box.h) / 6))
        let margin = max(8, band * 3)
        let frame = canvas.clamped(box.grown(by: margin))
        guard frame.w > 2, frame.h > 2 else { return nil }

        // Marking. Blind the fill to the ring just outside the box as well, then
        // check what it puts there against what is really there. Those pixels
        // are the same kind of surroundings the fill has to invent inside the
        // box, so getting them right is the closest thing to proof available
        // without knowing what was behind the thing being removed.
        var probe = Tile(canvas, frame: frame, hole: box.grown(by: band))
        solve(&probe)
        let errors = probe.disagreement(with: canvas, over: box.grown(by: band), excluding: box)
        let error = score(errors)

        var real = Tile(canvas, frame: frame, hole: box)
        solve(&real)
        real.write(into: &canvas)

        guard let out = canvas.image() else { return nil }
        return Attempt(image: out, error: error, spread: canvas.spread(around: box, band: band))
    }

    /// One number for how badly the fill did on the pixels it was marked on.
    ///
    /// The mean is the wrong summary. A hard edge crossing the hole is wrong by
    /// everything along a thin line and right everywhere else, so averaging it
    /// over the whole ring dilutes a catastrophe into a rounding error -- a red
    /// block meeting a blue one scored 9 out of 255, which reads as "fine". The
    /// worst tenth is what the eye will land on, so that is what gets graded.
    static func score(_ errors: [Double]) -> Double {
        guard !errors.isEmpty else { return .infinity }
        let sorted = errors.sorted()
        let cut = max(1, sorted.count / 10)
        return sorted.suffix(cut).reduce(0, +) / Double(cut)
    }

    // MARK: - Solving

    /// Settles the hole to its rim.
    ///
    /// Coarse first. Relaxation moves information one pixel per pass, so a
    /// hundred-pixel hole would need thousands of passes to hear about its own
    /// far edge. Halving the picture until the hole is a dozen pixels across,
    /// solving there, and carrying that answer back up gets the same result in
    /// a fixed handful of passes at every size.
    private static func solve(_ t: inout Tile) {
        if max(t.holeW, t.holeH) > 12, t.w > 8, t.h > 8, var half = t.halved() {
            solve(&half)
            t.seed(from: half)
        } else {
            t.seedFlat()
        }
        t.relax(passes: 24)
    }

    // MARK: - Pixels

    /// One rectangle of one picture, in the coordinates of the picture.
    struct IntRect {
        var x: Int, y: Int, w: Int, h: Int
        init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
        init(_ r: CGRect) {
            self.init(x: Int(r.minX), y: Int(r.minY), w: Int(r.width), h: Int(r.height))
        }
        func grown(by n: Int) -> IntRect { IntRect(x: x - n, y: y - n, w: w + 2 * n, h: h + 2 * n) }
        func contains(_ px: Int, _ py: Int) -> Bool {
            px >= x && py >= y && px < x + w && py < y + h
        }
    }

    /// A picture's pixels, straightened out to RGBA floats so the arithmetic
    /// below doesn't have to think about byte order or premultiplication.
    struct Canvas {
        let w: Int, h: Int
        var c: [Float]

        init?(_ image: CGImage) {
            w = image.width
            h = image.height
            guard w > 0, h > 0 else { return nil }
            c = []
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress,
                      let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            self.c = bytes.map { Float($0) }
        }

        func clamped(_ r: IntRect) -> IntRect {
            let x0 = max(0, r.x), y0 = max(0, r.y)
            return IntRect(x: x0, y: y0,
                           w: min(w, r.x + r.w) - x0, h: min(h, r.y + r.h) - y0)
        }

        /// How varied the ring just outside `box` is, 0 being one flat colour.
        /// Reported so the transcript can say WHY a fill was or wasn't offered.
        func spread(around box: IntRect, band: Int) -> Double {
            // Per channel, not summed. Summing made a red block and a blue one
            // the same number, which is exactly the case that most needs telling
            // apart.
            var values = [[Double]](repeating: [], count: 3)
            let outer = clamped(box.grown(by: band))
            for y in outer.y..<(outer.y + outer.h) {
                for x in outer.x..<(outer.x + outer.w) where !box.contains(x, y) {
                    let i = (y * w + x) * 4
                    for ch in 0..<3 { values[ch].append(Double(c[i + ch])) }
                }
            }
            guard values[0].count > 1 else { return 0 }
            return values.map { channel -> Double in
                let mean = channel.reduce(0, +) / Double(channel.count)
                return (channel.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
                        / Double(channel.count)).squareRoot()
            }.max() ?? 0
        }

        func image() -> CGImage? {
            var bytes = c.map { UInt8(max(0, min(255, $0.rounded()))) }
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

    /// The working area: a window of the picture plus a note of which of its
    /// pixels are the hole.
    struct Tile {
        var w: Int, h: Int
        var originX: Int, originY: Int
        var c: [Float]
        var hole: [Bool]
        var holeW: Int, holeH: Int

        init(_ canvas: Canvas, frame: IntRect, hole box: IntRect) {
            w = frame.w; h = frame.h
            originX = frame.x; originY = frame.y
            c = [Float](repeating: 0, count: w * h * 4)
            hole = [Bool](repeating: false, count: w * h)
            holeW = box.w; holeH = box.h
            for y in 0..<h {
                for x in 0..<w {
                    let src = ((y + frame.y) * canvas.w + (x + frame.x)) * 4
                    let dst = (y * w + x) * 4
                    for ch in 0..<4 { c[dst + ch] = canvas.c[src + ch] }
                    // Never hole the tile's own outer ring: the fill needs a
                    // rim of real pixels to settle towards, and a hole that
                    // reaches the edge has nothing holding it.
                    if x > 0, y > 0, x < w - 1, y < h - 1,
                       box.contains(x + frame.x, y + frame.y) {
                        hole[y * w + x] = true
                    }
                }
            }
        }

        private init(w: Int, h: Int, originX: Int, originY: Int,
                     c: [Float], hole: [Bool], holeW: Int, holeH: Int) {
            self.w = w; self.h = h; self.originX = originX; self.originY = originY
            self.c = c; self.hole = hole; self.holeW = holeW; self.holeH = holeH
        }

        /// Everything the hole should settle to, averaged. A flat start that is
        /// already the right colour, so the passes below only have to shape it.
        mutating func seedFlat() {
            var sum = [Float](repeating: 0, count: 4)
            var n: Float = 0
            for i in 0..<(w * h) where !hole[i] {
                for ch in 0..<4 { sum[ch] += c[i * 4 + ch] }
                n += 1
            }
            guard n > 0 else { return }
            for i in 0..<(w * h) where hole[i] {
                for ch in 0..<4 { c[i * 4 + ch] = sum[ch] / n }
            }
        }

        /// The same tile at half scale, for solving the shape of the fill
        /// cheaply before the detail.
        func halved() -> Tile? {
            let hw = w / 2, hh = h / 2
            guard hw > 3, hh > 3 else { return nil }
            var c2 = [Float](repeating: 0, count: hw * hh * 4)
            var hole2 = [Bool](repeating: false, count: hw * hh)
            for y in 0..<hh {
                for x in 0..<hw {
                    var sum = [Float](repeating: 0, count: 4)
                    var real: Float = 0
                    var all = true
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            let i = (y * 2 + dy) * w + (x * 2 + dx)
                            if hole[i] { continue }
                            all = false
                            for ch in 0..<4 { sum[ch] += c[i * 4 + ch] }
                            real += 1
                        }
                    }
                    // A coarse pixel is only hole when all four of its children
                    // are. Otherwise it keeps the average of the real ones, so
                    // the coarse rim is genuine picture rather than a guess.
                    hole2[y * hw + x] = all
                    if real > 0 {
                        for ch in 0..<4 { c2[(y * hw + x) * 4 + ch] = sum[ch] / real }
                    }
                }
            }
            return Tile(w: hw, h: hh, originX: originX, originY: originY,
                        c: c2, hole: hole2, holeW: max(1, holeW / 2), holeH: max(1, holeH / 2))
        }

        /// Carries a solved half-scale answer up as this tile's starting guess.
        mutating func seed(from small: Tile) {
            for y in 0..<h {
                let sy = min(small.h - 1, y / 2)
                for x in 0..<w where hole[y * w + x] {
                    let sx = min(small.w - 1, x / 2)
                    let src = (sy * small.w + sx) * 4
                    let dst = (y * w + x) * 4
                    for ch in 0..<4 { c[dst + ch] = small.c[src + ch] }
                }
            }
        }

        /// One pass of averaging every hole pixel with its four neighbours,
        /// reading the neighbours already updated this pass — which carries the
        /// rim inward about twice as fast as working from a copy would.
        mutating func relax(passes: Int) {
            guard w > 2, h > 2 else { return }
            for _ in 0..<passes {
                for y in 1..<(h - 1) {
                    for x in 1..<(w - 1) where hole[y * w + x] {
                        let i = (y * w + x) * 4
                        let up = i - w * 4, down = i + w * 4
                        for ch in 0..<4 {
                            c[i + ch] = (c[up + ch] + c[down + ch] + c[i - 4 + ch] + c[i + 4 + ch]) * 0.25
                        }
                    }
                }
            }
        }

        /// Average channel error against the real picture over `region`, skipping
        /// `skip`. Colour only: alpha is either there or it isn't and averaging
        /// its disagreement says nothing about whether the fill looks right.
        func disagreement(with canvas: Canvas, over region: IntRect, excluding skip: IntRect) -> [Double] {
            var errors: [Double] = []
            for y in region.y..<(region.y + region.h) {
                for x in region.x..<(region.x + region.w) where !skip.contains(x, y) {
                    let tx = x - originX, ty = y - originY
                    guard tx >= 0, ty >= 0, tx < w, ty < h else { continue }
                    let mine = (ty * w + tx) * 4
                    let theirs = (y * canvas.w + x) * 4
                    var worst = 0.0
                    for ch in 0..<3 {
                        worst = max(worst, Double(abs(c[mine + ch] - canvas.c[theirs + ch])))
                    }
                    errors.append(worst)
                }
            }
            return errors
        }

        /// Only the hole goes back. Everything else in the tile is untouched
        /// picture and rewriting it would be a chance to lose a pixel.
        func write(into canvas: inout Canvas) {
            for y in 0..<h {
                for x in 0..<w where hole[y * w + x] {
                    let src = (y * w + x) * 4
                    let dst = ((y + originY) * canvas.w + (x + originX)) * 4
                    for ch in 0..<4 { canvas.c[dst + ch] = c[src + ch] }
                }
            }
        }
    }
}
