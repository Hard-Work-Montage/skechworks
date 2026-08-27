import CoreGraphics
import Foundation

extension Page {

    /// Turns a shape's stroke into a filled shape of its own.
    ///
    /// A border is a way of PAINTING a path, not a shape — so a boolean
    /// operation, which works on shapes, sees a circle where you can see a ring
    /// and punches a disc instead of a hole. This makes the ring real: the
    /// outline becomes the geometry and the stroke goes away.
    ///
    /// Text goes the same way, to the letters' own outlines. Same idea, and the
    /// reason Sketch files this under one command rather than two.
    @discardableResult
    public mutating func convertToOutlines(_ id: String) -> Bool {
        guard let layer = self.layer(id) else { return false }

        if case .text(let run) = layer.kind {
            guard let glyphs = TextOutline.path(run, in: CGRect(origin: .zero, size: layer.frame.size))
            else { return false }
            updateLayer(id) { l in
                l.kind = .path(glyphs, closed: true)
                // The style carries over untouched. The canvas already fills
                // glyphs from it, so text with a green fill was green before
                // and has to be green after — overwriting it with the run's
                // colour turned every imported text layer black the moment it
                // stopped being text. Only a layer with no fill at all needs
                // the run's colour written down, since that is what the canvas
                // was falling back to.
                if l.style.fills.isEmpty { l.style.fills = [Fill(paint: .color(run.color))] }
            }
            return true
        }

        guard case .path = layer.kind, let border = layer.style.borders.first,
              border.thickness > 0, let shape = Compose.resolvedPath(layer) else { return false }

        guard let ring = outline(shape, border: border) else { return false }

        // A shape with a fill AND a border is two pictures: the filled middle and
        // the ring around it. Flattening them into one path would have to pick a
        // colour and lose the other, so they become a group of two shapes that
        // look exactly like what was there.
        if let fill = layer.style.fills.first {
            var middle = layer.withNewIDs()
            middle.style.borders = []
            middle.style.fills = [fill]
            middle.frame = CGRect(origin: .zero, size: layer.frame.size)
            middle.name = layer.name

            var edge = layer.withNewIDs()
            edge.kind = .path(ring, closed: true)
            edge.style.fills = [Fill(paint: .color(border.color))]
            edge.style.borders = []
            edge.frame = CGRect(origin: .zero, size: layer.frame.size)
            edge.name = layer.name + " outline"

            updateLayer(id) { l in
                l.kind = .group([middle, edge])
                l.style.fills = []
                l.style.borders = []
            }
            return true
        }

        updateLayer(id) { l in
            l.kind = .path(ring, closed: true)
            l.style.fills = [Fill(paint: .color(border.color))]
            l.style.borders = []
        }
        return true
    }

    /// The area a stroke covers, as a shape.
    private func outline(_ shape: CGPath, border: Border) -> CGPath? {
        // CoreGraphics strokes down the middle, which is what "center" means.
        // Inside and outside are that same band with the half that fell on the
        // wrong side of the path taken off — done with the boolean ops rather
        // than by stroking at double width, which rounds corners differently.
        let band = shape.copy(strokingWithWidth: border.thickness,
                              lineCap: CGLineCap(rawValue: Int32(border.cap.rawValue)) ?? .butt,
                              lineJoin: CGLineJoin(rawValue: Int32(border.join.rawValue)) ?? .miter,
                              miterLimit: 10)
        switch border.position {
        case .center:
            return band.normalized(using: .evenOdd)
        case .inside:
            let wide = shape.copy(strokingWithWidth: border.thickness * 2,
                                  lineCap: CGLineCap(rawValue: Int32(border.cap.rawValue)) ?? .butt,
                                  lineJoin: CGLineJoin(rawValue: Int32(border.join.rawValue)) ?? .miter,
                                  miterLimit: 10)
            return wide.intersection(shape).normalized(using: .evenOdd)
        case .outside:
            let wide = shape.copy(strokingWithWidth: border.thickness * 2,
                                  lineCap: CGLineCap(rawValue: Int32(border.cap.rawValue)) ?? .butt,
                                  lineJoin: CGLineJoin(rawValue: Int32(border.join.rawValue)) ?? .miter,
                                  miterLimit: 10)
            return wide.subtracting(shape).normalized(using: .evenOdd)
        }
    }
}
