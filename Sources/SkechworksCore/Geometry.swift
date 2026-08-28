import CoreGraphics
import Foundation

extension Page {

    /// Finds and repairs geometry no renderer can draw.
    ///
    /// A layer whose frame holds a NaN doesn't crash anything any more — the
    /// change detector was taught to survive it — but it draws nothing at all
    /// while sitting in the layer list looking present, which is a worse kind of
    /// wrong: a shape vanishes off a drawing and the thing that made it is long
    /// finished and out of sight.
    ///
    /// So it's caught where every edit passes through, and it says which layer
    /// it was. A repair that happens quietly is a bug that never gets fixed.
    public func repairingGeometry() -> (page: Page, repaired: [String]) {
        var broken: [String] = []

        func number(_ v: CGFloat, _ fallback: CGFloat) -> CGFloat {
            v.isFinite && abs(v) < 1e7 ? v : fallback
        }

        func fix(_ layers: [Layer]) -> [Layer] {
            layers.map { layer in
                var l = layer
                let f = l.frame
                let clean = CGRect(x: number(f.minX, 0), y: number(f.minY, 0),
                                   width: max(1, number(f.width, 1)),
                                   height: max(1, number(f.height, 1)))
                if clean != f {
                    broken.append(l.name.isEmpty ? l.id : l.name)
                    l.frame = clean
                }
                for i in l.style.borders.indices where !l.style.borders[i].thickness.isFinite {
                    broken.append((l.name.isEmpty ? l.id : l.name) + " (stroke)")
                    l.style.borders[i].thickness = 1
                }
                switch l.kind {
                case .group(let kids): l.kind = .group(fix(kids))
                case .shapeGroup(let kids, let winding): l.kind = .shapeGroup(fix(kids), winding)
                default: break
                }
                return l
            }
        }

        var out = self
        out.layers = fix(layers)
        return (out, broken)
    }
}
