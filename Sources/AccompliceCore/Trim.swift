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
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w where bytes[row + x * 4 + 3] > alphaAbove {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        // Unit coordinates, y down, so the caller can apply it to a frame or a
        // crop without knowing the pixel size.
        return CGRect(x: CGFloat(minX) / CGFloat(w),
                      y: CGFloat(minY) / CGFloat(h),
                      width: CGFloat(maxX - minX + 1) / CGFloat(w),
                      height: CGFloat(maxY - minY + 1) / CGFloat(h))
    }
}
