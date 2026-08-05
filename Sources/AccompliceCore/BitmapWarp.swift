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
        return "\(ref)|warp|\(c)|\(BitmapAdjust.key(ref: ref, l))" as NSString
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
