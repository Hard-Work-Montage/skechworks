import CoreGraphics
import Foundation

/// Where a picture actually has something in it.
public enum Trim {

    /// The box around every pixel that is not see-through, in unit coordinates
    /// of the image. Nil when the whole thing is empty.
    ///
    /// Wanted because erasing in this app is a stored decision rather than a
    /// cut: rub out the bottom half of a bitmap and the pixels are all still
    /// there, so the layer keeps a frame the full height of what it used to be.
    /// The handles then describe a picture that is no longer on the screen, and
    /// anything that measures the layer — Extend most of all — measures the
    /// ghost instead of the artwork.
    public static func contentBounds(_ image: CGImage, alphaAbove: UInt8 = 8) -> CGRect? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        // Sampled on anything big. This runs on every marquee erase, and a
        // full scan of a three-thousand-pixel-wide picture is fourteen
        // megabytes and three million reads for a number that is allowed to be
        // a couple of pixels out — the caller already ignores anything under a
        // fifth of a percent.
        let step = max(1, min(w, h) / 512)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in stride(from: 0, to: h, by: step) {
            let row = y * w * 4
            for x in stride(from: 0, to: w, by: step) where bytes[row + x * 4 + 3] > alphaAbove {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        // Unit coordinates, y down, so the caller can apply it to a frame or a
        // crop without knowing the pixel size.
        // Rounded outward by the sampling step, so a trim never cuts into
        // artwork it simply did not look at.
        let lo = { (v: Int) in max(0, v - step) }
        let hi = { (v: Int, limit: Int) in min(limit - 1, v + step) }
        let x0 = lo(minX), y0 = lo(minY), x1 = hi(maxX, w), y1 = hi(maxY, h)
        return CGRect(x: CGFloat(x0) / CGFloat(w),
                      y: CGFloat(y0) / CGFloat(h),
                      width: CGFloat(x1 - x0 + 1) / CGFloat(w),
                      height: CGFloat(y1 - y0 + 1) / CGFloat(h))
    }
}
