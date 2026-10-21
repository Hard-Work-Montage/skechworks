import CoreGraphics
import Foundation

/// Small dark dots taken out of a picture, the big shapes left alone.
///
/// The case this is for is Make Black and White on a coin whose light border
/// had worn texture in it: the border came out peppered with black dots the
/// same black as the lettering, so erasing by colour takes the lettering too
/// (Adam, 2026-10-21). Size tells them apart where colour can't. A dot is a
/// few pixels across; a letter, a ring or a leaf is many.
///
/// Each dot is painted over with the colour just outside it, so on black and
/// white it goes white and on a photo it takes the colour round it. Run it
/// again with a bigger size to take the next ones; Undo puts them back.
public enum Specks {

    /// Across, in the picture's own pixels.
    public static let defaultSize = 6

    public struct Result {
        public let image: CGImage
        public let removed: Int
    }

    /// Every dark patch no more than `size` pixels across, inside `within`
    /// (picture pixels, y-down) when there is one. Nil when the picture
    /// can't be read; `removed` is 0 when there was nothing that small.
    public static func remove(from image: CGImage, size: Int = defaultSize,
                              within: CGRect? = nil) -> Result? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
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

        // Ink: opaque and dark. Premultiplied, so a clear pixel's (0,0,0)
        // would otherwise read as black.
        var ink = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where px[i * 4 + 3] >= 128 {
            let lum = 0.299 * Float(px[i * 4]) + 0.587 * Float(px[i * 4 + 1]) + 0.114 * Float(px[i * 4 + 2])
            ink[i] = lum < Float(px[i * 4 + 3]) / 2
        }

        let box = within.map {
            (x0: max(0, Int($0.minX.rounded(.down))), y0: max(0, Int($0.minY.rounded(.down))),
             x1: min(w, Int($0.maxX.rounded(.up))), y1: min(h, Int($0.maxY.rounded(.up))))
        } ?? (x0: 0, y0: 0, x1: w, y1: h)
        guard box.x1 > box.x0, box.y1 > box.y0 else { return Result(image: image, removed: 0) }

        let limit = max(1, size)
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = [], patch: [Int] = []
        var removed = 0
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
                let start = y * w + x
                guard ink[start], !seen[start] else { continue }
                seen[start] = true
                stack.append(start)
                patch.removeAll(keepingCapacity: true)
                var minX = x, maxX = x, minY = y, maxY = y
                var big = false
                while let i = stack.popLast() {
                    patch.append(i)
                    let ix = i % w, iy = i / w
                    minX = min(minX, ix); maxX = max(maxX, ix)
                    minY = min(minY, iy); maxY = max(maxY, iy)
                    if maxX - minX >= limit || maxY - minY >= limit { big = true }
                    for dy in -1...1 {
                        let ny = iy + dy
                        guard ny >= 0, ny < h else { continue }
                        for dx in -1...1 {
                            let nx = ix + dx
                            guard nx >= 0, nx < w else { continue }
                            let j = ny * w + nx
                            if ink[j] && !seen[j] { seen[j] = true; stack.append(j) }
                        }
                    }
                }
                // Too big, or reaching out of the box: a shape, or a dot
                // that is only partly what was boxed. Leave it.
                guard !big, minX >= box.x0, maxX < box.x1, minY >= box.y0, maxY < box.y1 else { continue }
                fill(patch, in: &px, ink: ink, w: w, h: h)
                removed += 1
            }
        }
        guard removed > 0 else { return Result(image: image, removed: 0) }

        let out = px.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
        return out.map { Result(image: $0, removed: removed) }
    }

    /// Paints a dot, and the soft pixels on its edge, with the average of the
    /// ring just outside it. White when there's no ring to read.
    private static func fill(_ patch: [Int], in px: inout [UInt8], ink: [Bool], w: Int, h: Int) {
        var inPatch = Set(patch)
        // The edge of a dot that wasn't drawn hard is lighter than the cut-off
        // and would stay as a grey ring. One pixel out goes with it.
        var edge: [Int] = []
        for i in patch {
            let x = i % w, y = i / w
            for dy in -1...1 {
                for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let j = ny * w + nx
                    if !inPatch.contains(j) && !ink[j] { edge.append(j) }
                }
            }
        }
        inPatch.formUnion(edge)
        var sum = [Int](repeating: 0, count: 4), n = 0
        for i in edge {
            let x = i % w, y = i / w
            for dy in -1...1 {
                for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let j = ny * w + nx
                    guard !inPatch.contains(j), !ink[j] else { continue }
                    for c in 0..<4 { sum[c] += Int(px[j * 4 + c]) }
                    n += 1
                }
            }
        }
        let colour: [UInt8] = n > 0 ? sum.map { UInt8($0 / n) } : [255, 255, 255, 255]
        for i in inPatch {
            for c in 0..<4 { px[i * 4 + c] = colour[c] }
        }
    }
}
