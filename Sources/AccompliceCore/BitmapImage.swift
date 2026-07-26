import CoreGraphics
import Foundation
import ImageIO

// EXIF orientation handling.
//
// iPhone photos are stored in the sensor's native landscape and carry an orientation
// tag saying how to display them — a portrait shot is 4032x3024 pixels flagged
// "RightTop". `CGImageSourceCreateImageAtIndex` hands back the raw pixels and ignores
// that tag, so the photo renders 90° off and looks squashed when it lands in a
// portrait-shaped frame.
//
// Rather than re-encoding (which would destroy the original bytes we promise to
// preserve), we keep the pixels as they are and fold the orientation into the
// transform. One helper, used by both the rasterizer and the SVG writer, so the
// screen and the engraving file can't disagree about which way up a photo goes.

public enum BitmapImage {

    public struct Oriented {
        /// The image as stored, un-rotated.
        public let image: CGImage
        /// Pixel size as stored.
        public let nativeSize: CGSize
        /// Size once the orientation is applied — what the layer frame corresponds to.
        public let displaySize: CGSize
        /// Maps the native image rect onto the display box.
        public let transform: CGAffineTransform
        public var isRotated: Bool { !transform.isIdentity }
    }

    public static func load(_ data: Data) -> Oriented? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let native = CGSize(width: img.width, height: img.height)
        let (display, t) = transform(for: raw, native: native)
        return Oriented(image: img, nativeSize: native, displaySize: display, transform: t)
    }

    /// EXIF orientation -> (display size, transform mapping native pixels into it).
    /// Values 1-8 per the TIFF spec; 5-8 involve a 90° turn so width and height swap.
    static func transform(for orientation: UInt32, native: CGSize) -> (CGSize, CGAffineTransform) {
        let w = native.width, h = native.height
        switch orientation {
        case 2:   // mirrored horizontally
            return (native, CGAffineTransform(translationX: w, y: 0).scaledBy(x: -1, y: 1))
        case 3:   // 180°
            return (native, CGAffineTransform(translationX: w, y: h).rotated(by: .pi))
        case 4:   // mirrored vertically
            return (native, CGAffineTransform(translationX: 0, y: h).scaledBy(x: 1, y: -1))
        case 5:   // mirrored horizontally then rotated 90° CCW
            return (CGSize(width: h, height: w),
                    CGAffineTransform(scaleX: -1, y: 1).rotated(by: -.pi / 2))
        case 6:   // rotated 90° CW — the common iPhone portrait case
            return (CGSize(width: h, height: w),
                    CGAffineTransform(translationX: h, y: 0).rotated(by: .pi / 2))
        case 7:   // mirrored horizontally then rotated 90° CW
            return (CGSize(width: h, height: w),
                    CGAffineTransform(translationX: h, y: w)
                        .rotated(by: .pi / 2).scaledBy(x: 1, y: -1))
        case 8:   // rotated 90° CCW
            return (CGSize(width: h, height: w),
                    CGAffineTransform(translationX: 0, y: w).rotated(by: -.pi / 2))
        default:
            return (native, .identity)
        }
    }
}
