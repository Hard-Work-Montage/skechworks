import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Resolves a bitmap layer's stored adjustments — brightness, contrast, saturation,
/// crop — into pixels, on demand.
///
/// The source bytes are never modified; this is the same philosophy as erase
/// strokes, applied to colour. The result is baked in DISPLAY space (EXIF
/// orientation already applied), so callers draw it with a plain flip and no
/// orientation gymnastics — the crop rect is defined in display space, and applying
/// it before orientation would cut the wrong corner of a rotated photo.
public enum BitmapAdjust {

    /// Keyed by source ref + parameters. Renders happen per frame while the canvas
    /// is being panned, and a CoreImage round trip per frame would turn a photo
    /// layer into a slideshow.
    // NSCache is documented thread-safe; the checker can't see that.
    nonisolated(unsafe) private static let cache = NSCache<NSString, CGImage>()

    public static func key(ref: String, _ l: Layer) -> NSString {
        let c = l.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return "\(ref)|\(l.brightness)|\(l.contrast)|\(l.saturation)|\(c.origin.x),\(c.origin.y),\(c.width),\(c.height)" as NSString
    }

    /// The adjusted, cropped image in display orientation, or nil when the source
    /// can't be read. Neutral parameters still pay for orientation baking, so only
    /// call this when `layer.hasBitmapAdjustments` says there's work to do.
    public static func displayImage(data: Data, ref: String, layer l: Layer) -> CGImage? {
        let k = key(ref: ref, l)
        if let hit = cache.object(forKey: k) { return hit }
        guard let o = BitmapImage.load(data) else { return nil }

        // Into display orientation first.
        var image = o.image
        if !o.transform.isIdentity {
            let d = o.displaySize
            guard let ctx = CGContext(data: nil, width: Int(d.width), height: Int(d.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            // The EXIF transform is y-down; the context draws y-up.
            ctx.translateBy(x: 0, y: d.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.concatenate(o.transform)
            ctx.translateBy(x: 0, y: o.nativeSize.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: o.nativeSize))
            guard let baked = ctx.makeImage() else { return nil }
            image = baked
        }

        // Crop, in display pixels.
        if let c = l.cropRect {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let px = CGRect(x: (c.minX * w).rounded(), y: (c.minY * h).rounded(),
                            width: max(1, (c.width * w).rounded()),
                            height: max(1, (c.height * h).rounded()))
            if let cut = image.cropping(to: px) { image = cut }
        }

        // Colour.
        if l.brightness != 0 || l.contrast != 1 || l.saturation != 1 {
            let ci = CIImage(cgImage: image)
            let f = CIFilter(name: "CIColorControls")!
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(l.brightness, forKey: kCIInputBrightnessKey)
            f.setValue(l.contrast, forKey: kCIInputContrastKey)
            f.setValue(l.saturation, forKey: kCIInputSaturationKey)
            if let out = f.outputImage,
               let rendered = ciContext.createCGImage(out, from: ci.extent) {
                image = rendered
            }
        }

        cache.setObject(image, forKey: k)
        return image
    }

    /// PNG bytes of the adjusted image, for exports that embed pixels.
    public static func pngData(data: Data, ref: String, layer l: Layer) -> Data? {
        guard let img = displayImage(data: data, ref: ref, layer: l) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString,
                                                          1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    nonisolated(unsafe) private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
}
