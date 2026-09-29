import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// The things in a picture, found the way Photos lifts a subject off its
/// background: on this Mac, in about a second, for nothing.
///
/// It finds them and does not name them. One dog on a coin comes back as one
/// subject and that is the whole job. A family and a dog come back as several,
/// unlabelled, and choosing among them is for whoever can see the picture.
public enum Subjects {

    /// One subject as flags, one per image pixel, with its box.
    public struct Found: @unchecked Sendable {
        public var bits: [Bool]
        /// Image pixels, y down.
        public var box: CGRect
        public var area: Int
    }

    /// Every subject in the picture, biggest first. Empty on a Mac too old to
    /// have the request, and on a picture with nothing standing out.
    public static func find(in image: CGImage) -> [Found] {
        guard #available(macOS 14.0, *) else { return [] }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first else { return [] }
        let w = image.width, h = image.height
        var out: [Found] = []
        for instance in result.allInstances {
            guard let buffer = try? result.generateScaledMaskForImage(forInstances: [instance], from: handler),
                  let found = flags(buffer, w: w, h: h) else { continue }
            out.append(found)
        }
        return out.sorted { $0.area > $1.area }
    }

    /// A soft mask to hard flags, at the picture's own size.
    static func flags(_ buffer: CVPixelBuffer, w: Int, h: Int) -> Found? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), bw > 0, bh > 0 else { return nil }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let float = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float
        var bits = [Bool](repeating: false, count: w * h)
        var area = 0
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let sy = min(bh - 1, y * bh / h)
            let line = base.advanced(by: sy * row)
            for x in 0..<w {
                let sx = min(bw - 1, x * bw / w)
                let v: Float = float
                    ? line.assumingMemoryBound(to: Float.self)[sx]
                    : Float(line.assumingMemoryBound(to: UInt8.self)[sx]) / 255
                guard v >= 0.5 else { continue }
                bits[y * w + x] = true
                area += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard area > 0 else { return nil }
        return Found(bits: bits, box: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1),
                     area: area)
    }

    /// Everything in the picture except the chosen subjects, as rings to erase:
    /// one list per piece, outside edge first then its holes. Image pixels.
    ///
    /// A pixel of the background is left round each subject. Vision's edge is
    /// a soft one cut at half, and eating into a dog's ear looks worse than a
    /// hairline of the coin behind it.
    public static func background(of chosen: [Found], w: Int, h: Int, clear: [Bool]? = nil) -> [[[CGPoint]]] {
        var keep = [Bool](repeating: false, count: w * h)
        for s in chosen { for i in s.bits.indices where s.bits[i] { keep[i] = true } }
        let grown = keep
        for j in 0..<(w * h) where !grown[j] {
            KnockOut.forEachNeighbour(j, w: w, h: h) { k in if grown[k] { keep[j] = true } }
        }
        let erase = keep.indices.map { !keep[$0] && !(clear?[$0] ?? false) }
        return KnockOut.split(erase, w: w, h: h)
    }
}
