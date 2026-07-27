import CoreGraphics
import CoreText
import Foundation

// The Accomplice document model.
//
// Deliberately NOT a mirror of Sketch's JSON. Sketch's schema carries a decade of
// UI-tool baggage (symbols, overrides, constraints, prototyping) that we never read.
// This is the small model the renderer and the editor both want, and the Sketch
// reader's job is to collapse Sketch's shapes down into it.

// The model crosses threads: pages parse on a background task and land on the main
// actor. Everything here is a value type over immutable CGPaths — we always `.copy()`
// a path before storing it and never mutate one afterwards — so this is sound, but
// CGPath is a CF type the compiler can't reason about. Hence `@unchecked`.
public struct Document: @unchecked Sendable {
    public var pages: [Page] = []
    public var sourceApp: String?          // e.g. "Sketch 2026.2" — provenance, for the record
    public init() {}
}

public struct Page: @unchecked Sendable {
    public var name: String
    public var layers: [Layer] = []        // index 0 == BACK-most (Sketch's own order)
    public init(name: String) { self.name = name }

    /// Union of every layer's bounds. Sketch pages are an infinite canvas, so a page
    /// has no intrinsic frame — we derive one at render time.
    public func contentBounds() -> CGRect {
        let r = layers.filter(\.isVisible).map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        // An empty page still needs somewhere to draw. A 1x1 rect would zoom-to-fit to
        // an absurd magnification and make the pen tool unusable on a new document.
        return r.isNull ? CGRect(x: 0, y: 0, width: 1000, height: 1000) : r
    }

    /// Applies `body` to the layer with `id`, wherever it sits in the tree.
    ///
    /// The model is value types all the way down, so editing a nested layer means
    /// rebuilding the spine above it. Doing that in one place keeps every caller from
    /// hand-rolling tree surgery — and keeps undo simple, since a snapshot of the
    /// layer before and after is all an undo step ever needs.
    @discardableResult
    public mutating func updateLayer(_ id: String, _ body: (inout Layer) -> Void) -> Bool {
        Page.update(&layers, id, body)
    }

    public func layer(_ id: String) -> Layer? { Page.find(id, in: layers) }

    /// Removes a layer from anywhere in the tree, reporting where it was so it can be
    /// put back. Undo has to restore position, not just existence.
    @discardableResult
    public mutating func removeLayer(_ id: String) -> (parent: String?, index: Int, layer: Layer)? {
        func drop(_ ls: inout [Layer], _ parent: String?) -> (String?, Int, Layer)? {
            for i in ls.indices {
                if ls[i].id == id { return (parent, i, ls.remove(at: i)) }
                switch ls[i].kind {
                case .group(var k):
                    if let hit = drop(&k, ls[i].id) { ls[i].kind = .group(k); return hit }
                case .shapeGroup(var k, let rule):
                    if let hit = drop(&k, ls[i].id) { ls[i].kind = .shapeGroup(k, rule); return hit }
                default: continue
                }
            }
            return nil
        }
        return drop(&layers, nil)
    }

    /// Puts a layer back where it came from.
    public mutating func insertLayer(_ layer: Layer, parent: String?, index: Int) {
        guard let parent else {
            layers.insert(layer, at: min(index, layers.count))
            return
        }
        updateLayer(parent) { p in
            switch p.kind {
            case .group(var k): k.insert(layer, at: min(index, k.count)); p.kind = .group(k)
            case .shapeGroup(var k, let rule): k.insert(layer, at: min(index, k.count)); p.kind = .shapeGroup(k, rule)
            default: break
            }
        }
    }

    /// Ancestor ids from outermost inwards, excluding the layer itself. The layer list
    /// uses this to reveal a nested layer picked on the canvas.
    public func ancestors(of id: String) -> [String] {
        var trail: [String] = []
        func walk(_ ls: [Layer], _ acc: [String]) -> Bool {
            for l in ls {
                if l.id == id { trail = acc; return true }
                switch l.kind {
                case .group(let k), .shapeGroup(let k, _):
                    if walk(k, acc + [l.id]) { return true }
                default: continue
                }
            }
            return false
        }
        _ = walk(layers, [])
        return trail
    }

    private static func update(_ layers: inout [Layer], _ id: String,
                               _ body: (inout Layer) -> Void) -> Bool {
        for i in layers.indices {
            if layers[i].id == id { body(&layers[i]); return true }
            switch layers[i].kind {
            case .group(var kids):
                if update(&kids, id, body) { layers[i].kind = .group(kids); return true }
            case .shapeGroup(var kids, let rule):
                if update(&kids, id, body) { layers[i].kind = .shapeGroup(kids, rule); return true }
            default:
                continue
            }
        }
        return false
    }

    private static func find(_ id: String, in layers: [Layer]) -> Layer? {
        for l in layers {
            if l.id == id { return l }
            switch l.kind {
            case .group(let k), .shapeGroup(let k, _):
                if let hit = find(id, in: k) { return hit }
            default: continue
            }
        }
        return nil
    }
}

public enum BooleanOp: Int, Sendable {
    case none = -1, union = 0, subtract = 1, intersect = 2, difference = 3
}

public enum WindingRule: Int, Sendable {
    case nonZero = 0, evenOdd = 1
}

public indirect enum LayerKind: @unchecked Sendable {
    case group([Layer])
    /// A set of child shapes combined by boolean ops. This is where Sketch puts the style.
    case shapeGroup([Layer], WindingRule)
    /// A resolved outline in the layer's own coordinate space (origin at frame.origin).
    case path(CGPath, closed: Bool)
    case text(TextRun)
    case bitmap(imageRef: String)
}

public struct Layer: @unchecked Sendable {
    public var id: String = UUID().uuidString
    public var name: String = ""
    public var frame: CGRect = .zero
    public var rotation: CGFloat = 0        // degrees, counter-clockwise (Sketch convention)
    public var flipH = false
    public var flipV = false
    public var isVisible = true
    public var opacity: CGFloat = 1
    public var booleanOp: BooleanOp = .none
    public var hasClippingMask = false
    public var breaksMaskChain = false

    /// Artboards are groups with a job: they're the export unit. 70% of the artboards
    /// in the corpus carry an export preset, named `front` / `back` — they're how a
    /// coin's faces get cut out of a page, not a layout aid. They also paint a
    /// background and clip whatever hangs over the edge.
    public var isArtboard = false
    public var backgroundColor: Color?
    /// Sketch's "include background in export". The coin `front`/`back` artboards are
    /// white on canvas but set this false, so an engraving SVG has to come out
    /// transparent rather than with a white plate baked underneath.
    public var backgroundInExport = true
    public var style = Style()
    public var kind: LayerKind

    public init(kind: LayerKind) { self.kind = kind }

    public var bounds: CGRect { frame }

    /// This layer's id plus every descendant's. Dragging a group has to move all of
    /// its drawables, and the canvas needs to know which ones without recomposing.
    public var subtreeIDs: Set<String> {
        var out: Set<String> = [id]
        switch kind {
        case .group(let k), .shapeGroup(let k, _):
            for c in k { out.formUnion(c.subtreeIDs) }
        default: break
        }
        return out
    }

    /// Resizes the layer, scaling its contents to match.
    ///
    /// Paths are stored in absolute units inside the layer's own space, not normalized
    /// to the frame the way Sketch stores them. That makes rendering cheap but means a
    /// frame can't just be stretched — do that and the art stays put while its box
    /// grows, silently detaching the two. So the geometry is scaled here, and groups
    /// recurse: each child's origin and size scale, then the child rescales its own
    /// contents.
    public mutating func resize(to newSize: CGSize) {
        let old = frame.size
        guard old.width > 0, old.height > 0,
              newSize.width > 0, newSize.height > 0 else {
            frame.size = newSize
            return
        }
        let sx = newSize.width / old.width
        let sy = newSize.height / old.height
        guard sx != 1 || sy != 1 else { return }
        let scale = CGAffineTransform(scaleX: sx, y: sy)

        switch kind {
        case .path(let p, let closed):
            kind = .path(p.transformed(by: scale), closed: closed)

        case .group(var kids):
            Layer.scaleChildren(&kids, sx, sy)
            kind = .group(kids)

        case .shapeGroup(var kids, let rule):
            Layer.scaleChildren(&kids, sx, sy)
            kind = .shapeGroup(kids, rule)

        case .text(var t):
            // Scaling type non-uniformly would distort the glyphs, which no text tool
            // does — an uneven drag resizes the text box and lets the copy re-wrap.
            if abs(sx - sy) < 0.0001 {
                t.fontSize *= sx
                t.lineHeight *= sx
                t.kerning *= sx
                kind = .text(t)
            }

        case .bitmap:
            break   // the image is drawn to fit the frame, so the frame change is enough
        }
        frame.size = newSize
    }

    private static func scaleChildren(_ kids: inout [Layer], _ sx: CGFloat, _ sy: CGFloat) {
        for i in kids.indices {
            let f = kids[i].frame
            kids[i].frame.origin = CGPoint(x: f.minX * sx, y: f.minY * sy)
            kids[i].resize(to: CGSize(width: f.width * sx, height: f.height * sy))
        }
    }
}

// MARK: - Style

public struct Color: Sendable {
    public var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    public init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }
    public static let black = Color(r: 0, g: 0, b: 0, a: 1)

    public var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// `#rrggbb`, for SVG. Alpha travels separately as fill-opacity.
    public var hex: String {
        func c(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "#%02x%02x%02x", c(r), c(g), c(b))
    }
}

public enum GradientKind: Int, Sendable { case linear = 0, radial = 1, angular = 2 }

public struct Gradient: Sendable {
    public var kind: GradientKind = .linear
    public var from: CGPoint = .init(x: 0.5, y: 0)   // unit space within the layer
    public var to: CGPoint = .init(x: 0.5, y: 1)
    public var stops: [(position: CGFloat, color: Color)] = []
    public init() {}
}

public enum Paint: Sendable {
    case color(Color)
    case gradient(Gradient)
}

public struct Fill: Sendable {
    public var paint: Paint
    public var opacity: CGFloat = 1
    public init(paint: Paint, opacity: CGFloat = 1) { self.paint = paint; self.opacity = opacity }
}

public enum BorderPosition: Int, Sendable { case center = 0, inside = 1, outside = 2 }

public struct Border: Sendable {
    public var color: Color = .black
    public var thickness: CGFloat = 1
    public var position: BorderPosition = .center
    public var dashPattern: [CGFloat] = []
    public init() {}
}

public struct Shadow: Sendable {
    public var color: Color = Color(r: 0, g: 0, b: 0, a: 0.5)
    public var offset: CGSize = .init(width: 0, height: 2)
    public var blur: CGFloat = 4
    public var spread: CGFloat = 0
    public init() {}
}

public struct Style: Sendable {
    public var fills: [Fill] = []
    public var borders: [Border] = []
    public var shadows: [Shadow] = []
    public var opacity: CGFloat = 1
    public init() {}
}

// MARK: - Text

public struct TextRun: @unchecked Sendable {
    public var string: String = ""
    public var fontName: String = "Helvetica"
    public var fontSize: CGFloat = 12
    public var color: Color = .black
    public var kerning: CGFloat = 0
    public var lineHeight: CGFloat = 0      // 0 == use the font's natural leading
    public var alignment: CTTextAlignment = .left
    public init() {}
}
