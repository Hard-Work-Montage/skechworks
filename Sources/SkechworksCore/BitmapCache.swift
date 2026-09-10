import CoreGraphics
import Foundation
import ImageIO

// Decoded pictures, kept between frames.
//
// A picture layer was decoded from its PNG bytes on every draw, and the canvas
// draws on every scroll tick. A listing page with eighteen coin photos on it
// was eighteen PNG decodes per tick, which is what a bogged-down pan is.
//
// Two caches here. `BitmapImage.load(_:ref:)` decodes once and keeps the
// pixels. `BitmapMips` hands back a copy already shrunk to about the size the
// picture lands on screen, so CoreGraphics is not resampling 1.2 megapixels
// down to a postage stamp sixty times a second. Both are NSCaches: memory
// pressure empties them and the next frame just decodes again.

extension BitmapImage {

    final class Box {
        let oriented: Oriented
        init(_ o: Oriented) { oriented = o }
    }

    // NSCache is documented thread-safe; the checker can't see that.
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.totalCostLimit = 768 << 20
        return c
    }()

    /// `load(_:)` with the decode remembered. `ref` is the document's name for
    /// the picture; it joins a fingerprint of the bytes in the key, so a
    /// picture replaced under the same name is decoded afresh.
    public static func load(_ data: Data, ref: String) -> Oriented? {
        let k = "\(ref)|\(data.count)|\(fingerprint(data))" as NSString
        if let hit = cache.object(forKey: k) { return hit.oriented }
        guard let o = load(data, decodeNow: true) else { return nil }
        cache.setObject(Box(o), forKey: k, cost: o.image.width * o.image.height * 4)
        return o
    }

    /// Drops every remembered decode. Tests use it; the app never needs to.
    public static func forgetDecodes() { cache.removeAllObjects() }

    /// A cheap stand-in for hashing the whole file: the length, the head, the
    /// tail, and sixteen windows through the middle. Two different pictures
    /// agreeing on all of that, under the same ref, is not a case worth the
    /// cost of reading every byte on every frame.
    static func fingerprint(_ data: Data) -> Int {
        var h = Hasher()
        h.combine(data.count)
        data.withUnsafeBytes { buf in
            let n = buf.count
            guard n > 0 else { return }
            h.combine(bytes: UnsafeRawBufferPointer(rebasing: buf[0..<min(n, 4096)]))
            if n > 8192 {
                h.combine(bytes: UnsafeRawBufferPointer(rebasing: buf[(n - 4096)..<n]))
            }
            if n > 16384 {
                for i in 1...16 {
                    let off = n * i / 17
                    h.combine(bytes: UnsafeRawBufferPointer(rebasing: buf[off..<min(n, off + 256)]))
                }
            }
        }
        return h.finalize()
    }
}

public enum BitmapMips {

    final class Entry {
        let source: CGImage
        /// `levels[k]` is the source shrunk by 2^(k+1). Built on demand.
        var levels: [CGImage] = []
        let lock = NSLock()
        init(_ s: CGImage) { source = s }
    }

    // NSCache is documented thread-safe; the checker can't see that.
    nonisolated(unsafe) private static let cache: NSCache<NSNumber, Entry> = {
        let c = NSCache<NSNumber, Entry>()
        c.totalCostLimit = 512 << 20
        return c
    }()

    /// The source, or a copy of it halved as many times as fits while still
    /// keeping at least one pixel of picture per device pixel. `scale` is
    /// device pixels per source pixel: a 1000-pixel photo shown 250 pixels
    /// wide on a Retina screen is 0.5, and gets the half-size copy.
    ///
    /// Keyed on the image object itself. The entry holds the source, so its
    /// address cannot be reused by another picture while the entry lives; the
    /// identity check covers the moment after it is evicted.
    public static func image(_ src: CGImage, scale: CGFloat) -> CGImage {
        guard scale > 0, scale.isFinite, scale < 0.5 else { return src }
        var n = 0
        var w = src.width, h = src.height
        while CGFloat(1 << (n + 1)) <= 1 / scale, w >= 64, h >= 64 {
            n += 1; w /= 2; h /= 2
        }
        guard n > 0 else { return src }

        let key = NSNumber(value: UInt(bitPattern: Unmanaged.passUnretained(src).toOpaque()))
        let entry: Entry
        if let hit = cache.object(forKey: key), hit.source === src {
            entry = hit
        } else {
            entry = Entry(src)
            cache.setObject(entry, forKey: key, cost: src.width * src.height * 2)
        }
        entry.lock.lock()
        defer { entry.lock.unlock() }
        while entry.levels.count < n {
            guard let next = halve(entry.levels.last ?? src) else { break }
            entry.levels.append(next)
        }
        return entry.levels.isEmpty ? src : entry.levels[min(n, entry.levels.count) - 1]
    }

    /// One 2x reduction. Drawing into a half-size context lets CoreGraphics
    /// box-filter it, which is what a clean downsample is.
    static func halve(_ img: CGImage) -> CGImage? {
        let w = max(1, img.width / 2), h = max(1, img.height / 2)
        let space = (img.colorSpace?.model == .rgb ? img.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
