import CoreGraphics
import Foundation

/// Round to Pixel, on request.
///
/// A resize by hand lands on 791.8 by 792.1, a traced picture sits at 1.25, and
/// every export, every alignment and every artboard downstream inherits the
/// fraction. On a coin that was a disc a hair past its board and a clip
/// rectangle cut on the laser. From 0.1.59 to 0.1.62 every committed edit
/// rounded the frames it touched, and that reached the layer a Subtract had
/// just made: its frame rounded and its contents scaled to fit, so the cut came
/// out bent. Figma and Sketch only snap while you drag and never touch stored
/// geometry; Sketch's Round to Nearest Pixel Edge is the explicit version, and
/// that is what this is now, under Arrange > Round to Pixel.
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
