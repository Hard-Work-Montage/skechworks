import CoreGraphics
import Foundation

/// Baking several layers down into one picture.
///
/// Path ▸ Flatten already exists and is a different verb: it welds shapes
/// together into one outline and only understands vectors. This is the raster
/// one — whatever is selected, drawn exactly as it looks, as a single bitmap.
///
/// The reason it is wanted is that a piece composed out of six overlapping
/// layers cannot be worked on as a picture. Extend, Remove and the eraser all
/// act on one bitmap, so a figure built from a pose, two pasted patches and a
/// background has to be made into a picture before any of them apply to it.
public enum Flatten {

    /// How many pixels to draw per point, so nothing in the selection is
    /// resampled down.
    ///
    /// Taken from the sharpest thing in it. Flattening a 3,000-pixel piece that
    /// happens to sit in a 300-point frame at one pixel per point would throw
    /// nine tenths of it away, and there is no undo for detail that was never
    /// drawn — the layers are gone by then.
    public static func scale(for layers: [Layer], images: [String: Data], bounds: CGRect) -> CGFloat {
        var best: CGFloat = 1
        for l in layers {
            guard case .bitmap(let ref) = l.kind, let data = images[ref],
                  let o = BitmapImage.load(data), l.frame.width > 0 else { continue }
            best = max(best, o.displaySize.width / l.frame.width)
        }
        // Four is the renderer's own ceiling, and the long edge is capped so a
        // careless selection cannot ask for a picture nothing can hold.
        let cap = 8192 / max(bounds.width, bounds.height, 1)
        return max(1, min(best, 4, cap))
    }

    /// The upright box a layer covers once it has been turned.
    ///
    /// `Layer.bounds` is the frame, which is the box BEFORE any rotation. A
    /// picture at eight degrees reaches past it at two opposite corners, and
    /// flattening to the frame cut those corners off — the phone lost its top
    /// left and bottom right.
    public static func box(of l: Layer) -> CGRect {
        let r = l.bounds
        guard l.rotation != 0, r.width > 0, r.height > 0 else { return r }
        let turn = CGAffineTransform(translationX: r.midX, y: r.midY)
            .rotated(by: l.rotation * .pi / 180)
            .translatedBy(x: -r.midX, y: -r.midY)
        return r.applying(turn)
    }

    /// The box the flattened picture occupies: everything the selection covers.
    public static func bounds(of layers: [Layer]) -> CGRect? {
        let boxes = layers.filter(\.isVisible).map(box)
        guard !boxes.isEmpty else { return nil }
        let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        return union.width > 0 && union.height > 0 ? union : nil
    }
}
