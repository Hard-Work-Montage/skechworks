import CoreGraphics
import CoreImage
import Foundation

/// Projects a bitmap onto the quad its warp corners describe — the perspective
/// half of Fireworks' free transform, done with Core Image so the pixels are
/// resampled once, properly.
///
/// Corners are unit coordinates of the layer frame, y-down, in the order
/// top-left, top-right, bottom-right, bottom-left. The result is the warped
/// image plus where to draw it: a bounding box in the same unit space, which
/// can spill outside 0…1 when a corner is dragged past the frame.
public enum BitmapWarp {

    // NSCache is documented thread-safe; the checker can't see that.
    nonisolated(unsafe) private static let cache = NSCache<NSString, CacheEntry>()

    final class CacheEntry {
        let image: CGImage
        let box: CGRect
        init(_ image: CGImage, _ box: CGRect) { self.image = image; self.box = box }
    }

    public static func key(ref: String, _ l: Layer) -> NSString? {
        guard let w = l.warpCorners, w.count == 4 else { return nil }
        let c = w.map { "\($0.x),\($0.y)" }.joined(separator: "|")
        // Erase strokes are cut before the warp, so they belong in the cache key —
        // a cheap signature beats hashing every dab.
        var e: CGFloat = 0
        for s in l.erased {
            e += (s.rect?.minX ?? 0) + (s.rect?.minY ?? 0) + s.radius
            for p in s.points { e += p.x + p.y }
        }
        return "\(ref)|warp|\(c)|e\(l.erased.count),\(e)|\(BitmapAdjust.key(ref: ref, l))" as NSString
    }

    /// The full pipeline for a warped bitmap: bake the display image, cut the
    /// erase holes in flat space, then project — so erases travel with the
    /// picture instead of being lost the moment a corner moves.
    public static func warpedDisplayImage(data: Data, ref: String,
                                          layer l: Layer) -> (image: CGImage, unitBox: CGRect)? {
        guard let corners = l.warpCorners, corners.count == 4,
              let baked = BitmapAdjust.displayImage(data: data, ref: ref, layer: l) else { return nil }
        let cacheKey = key(ref: ref, l)
        if let cacheKey, let hit = cache.object(forKey: cacheKey) {
            return (hit.image, hit.box)
        }
        var source = baked
        if !l.erased.isEmpty, l.frame.width > 0,
           let mask = EraseMask.image(strokes: l.erased, size: l.frame.size),
           let cut = masked(baked, with: mask) {
            source = cut
        }
        return image(source, corners: corners, cacheKey: cacheKey)
    }

    /// The pixels a layer actually shows: baked for orientation, adjustments
    /// and crop, with its erasing taken out.
    ///
    /// Anything that needs to know how big a picture really is has to ask this
    /// rather than the frame. Erasing is a stored decision, not a cut, so a
    /// layer whose bottom half has been rubbed out still has a frame the full
    /// height of what it used to be.
    public static func visibleImage(data: Data, ref: String, layer l: Layer) -> CGImage? {
        guard let baked = BitmapAdjust.displayImage(data: data, ref: ref, layer: l) else { return nil }
        guard !l.erased.isEmpty, l.frame.width > 0,
              let mask = EraseMask.image(strokes: l.erased, size: l.frame.size),
              let cut = masked(baked, with: mask) else { return baked }
        return cut
    }

    /// Applies an erase mask (built in layer units) to a pixel-sized image.
    /// clip(to:mask:) stretches the mask to the rect, which also absorbs any
    /// difference between the frame's aspect and the pixels'.
    private static func masked(_ src: CGImage, with mask: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: src.width, height: src.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let r = CGRect(x: 0, y: 0, width: src.width, height: src.height)
        ctx.clip(to: r, mask: mask)
        ctx.draw(src, in: r)
        return ctx.makeImage()
    }

    /// The warped image and its bounding box in unit coordinates of the frame.
    public static func image(_ src: CGImage, corners: [CGPoint],
                             cacheKey: NSString? = nil) -> (image: CGImage, unitBox: CGRect)? {
        guard corners.count == 4 else { return nil }
        if let cacheKey, let hit = cache.object(forKey: cacheKey) {
            return (hit.image, hit.box)
        }
        let w = CGFloat(src.width), h = CGFloat(src.height)
        guard w > 0, h > 0 else { return nil }
        // Unit corners to pixels, then into Core Image's y-up space.
        let pts = corners.map { CGPoint(x: $0.x * w, y: h - $0.y * h) }
        let filter = CIFilter(name: "CIPerspectiveTransform")!
        filter.setValue(CIImage(cgImage: src), forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: pts[0]), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: pts[1]), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: pts[2]), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: pts[3]), forKey: "inputBottomLeft")
        guard let out = filter.outputImage else { return nil }
        let extent = out.extent.integral
        // A degenerate quad (three corners in a line, or corners flung to the
        // horizon) explodes the extent; refuse rather than allocate a gigapixel.
        guard extent.width >= 1, extent.height >= 1,
              extent.width <= 16384, extent.height <= 16384 else { return nil }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(out, from: extent) else { return nil }
        // Extent back to unit space, y-down.
        let box = CGRect(x: extent.minX / w,
                         y: (h - extent.maxY) / h,
                         width: extent.width / w,
                         height: extent.height / h)
        if let cacheKey { cache.setObject(CacheEntry(cg, box), forKey: cacheKey) }
        return (cg, box)
    }
}
