import CoreGraphics
import Foundation

/// Frames live on whole numbers.
///
/// A resize by hand lands on 791.8 by 792.1, a traced picture sits at 1.25, and
/// every export, every alignment and every artboard downstream inherits the
/// fraction. On a coin that was a disc a hair past its board and a clip
/// rectangle cut on the laser. So a committed edit leaves whatever frames it
/// touched rounded, contents scaled with the box the way resize always has.
/// Vector points are not frames and are left exactly where they were put.
extension Layer {
    public var frameIsWhole: Bool {
        frame.minX == frame.minX.rounded() && frame.minY == frame.minY.rounded()
            && frame.width == frame.width.rounded() && frame.height == frame.height.rounded()
    }

    /// Rounds the frame, scaling the contents to the rounded size. Never below 1.
    public mutating func snapFrameToWholeNumbers() {
        guard !frameIsWhole else { return }
        let size = CGSize(width: max(1, frame.width.rounded()), height: max(1, frame.height.rounded()))
        if size != frame.size { resize(to: size) }
        frame.origin = CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded())
    }
}

extension Page {
    /// Rounds every frame that differs from `before`, parents before children so
    /// a group's rounding reaches its kids before they round themselves.
    /// Returns the ids it touched.
    @discardableResult
    public mutating func snapChangedFrames(since before: Page) -> [String] {
        var was: [String: CGRect] = [:]
        for l in before.layersInOrder() { was[l.id] = l.frame }
        var touched: [String] = []
        for l in layersInOrder() where was[l.id] != l.frame && !l.frameIsWhole {
            if updateLayer(l.id, { $0.snapFrameToWholeNumbers() }) { touched.append(l.id) }
        }
        return touched
    }
}
