import CoreGraphics
import Foundation

/// Scoring a drawing against the picture it was drawn from.
///
/// The point of this is not to grade the result for a human. It's to close the
/// loop for a model: a vision model asked to trace an image is poor at emitting
/// coordinates in one shot and good at correcting them when told which way it's
/// wrong. One number says whether the last edit helped; the error map says where
/// to look next. Without both, a trace is a single blind guess.
public enum Compare {

    /// How alike two renders are, 1 being identical.
    ///
    /// Mean per-channel distance rather than anything perceptual. A drawing that's
    /// the right shape in the wrong grey should score close, and a shape in the
    /// wrong PLACE should score badly, which plain distance gets right and most
    /// clever metrics soften.
    public static func score(_ a: CGImage, _ b: CGImage, resolution: Int = 240) -> Double {
        let cells = errors(a, b, cells: 1, resolution: resolution)
        return 1 - (cells.first?.first ?? 1)
    }

    /// How much of the ink lines up: marks in both, over marks in either.
    ///
    /// The number that actually means something for a drawing, and the reason the
    /// first version of this loop was steering on noise. Per-pixel agreement is
    /// dominated by the background — an icon that is 80% white scores 80% for a
    /// BLANK page, and a real trace of it scores 82%. Two numbers no model can tell
    /// apart and nothing can be improved against. Counting only the marks, a blank
    /// page scores 0 and every correction moves the number.
    public static func inkAgreement(_ drawing: CGImage, _ reference: CGImage,
                                    resolution: Int = 240) -> Double {
        let side = max(16, resolution)
        guard let a = sample(drawing, side: side), let b = sample(reference, side: side) else { return 0 }

        // Whatever the original is mostly made of is its background, so this works
        // for black-on-white, white-on-black and a coloured plate alike.
        var counts: [Int: Int] = [:]
        for i in stride(from: 0, to: b.count, by: 4) {
            counts[Int(b[i]) << 16 | Int(b[i + 1]) << 8 | Int(b[i + 2]), default: 0] += 1
        }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
        let br = background >> 16 & 0xFF, bg = background >> 8 & 0xFF, bb = background & 0xFF

        func isInk(_ p: [UInt8], _ i: Int) -> Bool {
            max(abs(Int(p[i]) - br), abs(Int(p[i + 1]) - bg), abs(Int(p[i + 2]) - bb)) > 48
        }
        var both = 0, either = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            let x = isInk(a, i), y = isInk(b, i)
            if x && y { both += 1 }
            if x || y { either += 1 }
        }
        return either == 0 ? 1 : Double(both) / Double(either)
    }

    /// Error per cell of a `cells`×`cells` grid, row 0 at the top, 0 perfect and
    /// 1 completely wrong.
    public static func errors(_ a: CGImage, _ b: CGImage,
                              cells: Int = 6, resolution: Int = 240) -> [[Double]] {
        let n = max(1, cells)
        let side = max(n, (resolution / n) * n)
        guard let pa = sample(a, side: side), let pb = sample(b, side: side) else {
            return Array(repeating: Array(repeating: 1.0, count: n), count: n)
        }
        let step = side / n
        var out = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for row in 0..<n {
            for col in 0..<n {
                var total = 0.0
                for y in (row * step)..<((row + 1) * step) {
                    for x in (col * step)..<((col + 1) * step) {
                        let i = (y * side + x) * 4
                        let dr = abs(Int(pa[i]) - Int(pb[i]))
                        let dg = abs(Int(pa[i + 1]) - Int(pb[i + 1]))
                        let db = abs(Int(pa[i + 2]) - Int(pb[i + 2]))
                        total += Double(dr + dg + db) / 3.0
                    }
                }
                out[row][col] = total / Double(step * step) / 255.0
            }
        }
        return out
    }

    /// The regions that differ most, worst first, in the coordinates of `bounds`.
    ///
    /// What a model does with a bad score is look closer, and this is the crop to
    /// ask for.
    public static func hotspots(_ a: CGImage, _ b: CGImage, in bounds: CGRect,
                                cells: Int = 6, limit: Int = 3) -> [CGRect] {
        let grid = errors(a, b, cells: cells)
        let n = grid.count
        let w = bounds.width / CGFloat(n), h = bounds.height / CGFloat(n)
        var ranked: [(Double, CGRect)] = []
        for row in 0..<n {
            for col in 0..<n where grid[row][col] > 0.02 {
                ranked.append((grid[row][col], CGRect(x: bounds.minX + CGFloat(col) * w,
                                                      y: bounds.minY + CGFloat(row) * h,
                                                      width: w, height: h)))
            }
        }
        return ranked.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    /// The comparison written for a model to read back.
    ///
    /// A grid of digits rather than a list of numbers because the shape of the
    /// mistake is the useful part — a whole edge lit up reads as "everything is
    /// shifted", one hot cell reads as "one shape is wrong" — and that pattern
    /// survives being flattened into text where a table of decimals doesn't.
    public static func report(_ drawing: CGImage, against reference: CGImage,
                              bounds: CGRect? = nil, cells: Int = 6) -> String {
        let grid = errors(drawing, reference, cells: cells)
        let overall = grid.flatMap { $0 }.reduce(0, +) / Double(cells * cells)
        // Ink first. The pixel figure is along for the ride because it is what the
        // error map below is made of, but on its own it flatters everything.
        let ink = Int((inkAgreement(drawing, reference) * 100).rounded())
        var lines = ["ink match \(ink)% — of the marks in the original, how many you have drawn in the right place",
                     "pixel match \(Int(((1 - overall) * 100).rounded()))%",
                     "\(cells)×\(cells) error map over the compared area, 0 best 9 worst:"]
        for row in grid {
            lines.append(row.map { String(min(9, Int(($0 * 10).rounded()))) }.joined(separator: " "))
        }
        if let bounds {
            let spots = hotspots(drawing, reference, in: bounds, cells: cells)
            if spots.isEmpty {
                lines.append("nothing stands out — the remaining error is spread thin.")
            } else {
                lines.append("worst areas, x y w h: " + spots.map {
                    "(\(Int($0.minX)) \(Int($0.minY)) \(Int($0.width)) \(Int($0.height)))"
                }.joined(separator: ", "))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The two pictures laid on top of each other, colour-coded.
    ///
    /// Grey is ink in the original that hasn't been drawn. Red is ink drawn where
    /// the original has none. Black is agreement. Handing a model its attempt and
    /// the original as two separate pictures asks it to hold both in its head and
    /// spot a forty-pixel shift by memory, which is the same eyeballing that puts
    /// the strokes in the wrong place to begin with. Overlaid, "this finger is too
    /// long" is a red tip on a grey stub, and it needs no comparing at all.
    public static func overlay(_ drawing: CGImage, _ reference: CGImage,
                               resolution: Int = 512) -> CGImage? {
        let side = max(64, resolution)
        guard let a = sample(drawing, side: side), let b = sample(reference, side: side),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let out = ctx.data else { return nil }

        var counts: [Int: Int] = [:]
        for i in stride(from: 0, to: b.count, by: 4) {
            counts[Int(b[i]) << 16 | Int(b[i + 1]) << 8 | Int(b[i + 2]), default: 0] += 1
        }
        let background = counts.max(by: { $0.value < $1.value })?.key ?? 0xFFFFFF
        let br = background >> 16 & 0xFF, bg = background >> 8 & 0xFF, bb = background & 0xFF
        func isInk(_ p: [UInt8], _ i: Int) -> Bool {
            max(abs(Int(p[i]) - br), abs(Int(p[i + 1]) - bg), abs(Int(p[i + 2]) - bb)) > 48
        }

        let pixels = out.bindMemory(to: UInt8.self, capacity: side * side * 4)
        for i in stride(from: 0, to: a.count, by: 4) {
            let mine = isInk(a, i), theirs = isInk(b, i)
            let colour: (UInt8, UInt8, UInt8)
            switch (mine, theirs) {
            case (true, true):   colour = (20, 20, 20)      // agreed
            case (true, false):  colour = (230, 40, 40)     // drawn where nothing is
            case (false, true):  colour = (190, 190, 190)   // missed
            case (false, false): colour = (255, 255, 255)
            }
            pixels[i] = colour.0; pixels[i + 1] = colour.1; pixels[i + 2] = colour.2
            pixels[i + 3] = 255
        }
        return ctx.makeImage()
    }

    /// Renders part of a page at the same pixel size as something to compare it
    /// against, so the two line up without either being rescaled first.
    public static func render(_ page: Page, bounds: CGRect, matching reference: CGImage,
                             images: [String: Data] = [:]) -> CGImage? {
        let target = CGFloat(max(reference.width, reference.height))
        return Renderer(images: images, background: Color(r: 1, g: 1, b: 1, a: 1))
            .render(page: page, maxDimension: max(32, target), bounds: bounds)
    }

    /// Both images flattened onto white at a common size.
    ///
    /// Compositing matters: a traced shape sitting on transparency and no shape at
    /// all are the same pixels once alpha is ignored, and every trace would score
    /// perfectly against an empty page.
    private static func sample(_ image: CGImage, side: Int) -> [UInt8]? {
        let bytesPerRow = side * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * side)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? buffer : nil
    }
}
