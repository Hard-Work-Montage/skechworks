import CoreGraphics
import CoreText
import Foundation

// The Accomplice document model.
//
// Deliberately NOT a mirror of Sketch's JSON. Sketch's schema carries a decade of
// UI-tool baggage (symbols, overrides, constraints, prototyping) that we never read.
// This is the small model the renderer and the editor both want, and the Sketch
// reader's job is to collapse Sketch's shapes down into it.

public struct Document {
    public var pages: [Page] = []
    public var sourceApp: String?          // e.g. "Sketch 2026.2" — provenance, for the record
    public init() {}
}

public struct Page {
    public var name: String
    public var layers: [Layer] = []        // index 0 == BACK-most (Sketch's own order)
    public init(name: String) { self.name = name }

    /// Union of every layer's bounds. Sketch pages are an infinite canvas, so a page
    /// has no intrinsic frame — we derive one at render time.
    public func contentBounds() -> CGRect {
        let r = layers.filter(\.isVisible).map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        return r.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : r
    }
}

public enum BooleanOp: Int {
    case none = -1, union = 0, subtract = 1, intersect = 2, difference = 3
}

public enum WindingRule: Int {
    case nonZero = 0, evenOdd = 1
}

public indirect enum LayerKind {
    case group([Layer])
    /// A set of child shapes combined by boolean ops. This is where Sketch puts the style.
    case shapeGroup([Layer], WindingRule)
    /// A resolved outline in the layer's own coordinate space (origin at frame.origin).
    case path(CGPath, closed: Bool)
    case text(TextRun)
    case bitmap(imageRef: String)
}

public struct Layer {
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
    public var style = Style()
    public var kind: LayerKind

    public init(kind: LayerKind) { self.kind = kind }

    public var bounds: CGRect { frame }
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

public enum GradientKind: Int { case linear = 0, radial = 1, angular = 2 }

public struct Gradient {
    public var kind: GradientKind = .linear
    public var from: CGPoint = .init(x: 0.5, y: 0)   // unit space within the layer
    public var to: CGPoint = .init(x: 0.5, y: 1)
    public var stops: [(position: CGFloat, color: Color)] = []
    public init() {}
}

public enum Paint {
    case color(Color)
    case gradient(Gradient)
}

public struct Fill {
    public var paint: Paint
    public var opacity: CGFloat = 1
    public init(paint: Paint, opacity: CGFloat = 1) { self.paint = paint; self.opacity = opacity }
}

public enum BorderPosition: Int { case center = 0, inside = 1, outside = 2 }

public struct Border {
    public var color: Color = .black
    public var thickness: CGFloat = 1
    public var position: BorderPosition = .center
    public var dashPattern: [CGFloat] = []
    public init() {}
}

public struct Shadow {
    public var color: Color = Color(r: 0, g: 0, b: 0, a: 0.5)
    public var offset: CGSize = .init(width: 0, height: 2)
    public var blur: CGFloat = 4
    public var spread: CGFloat = 0
    public init() {}
}

public struct Style {
    public var fills: [Fill] = []
    public var borders: [Border] = []
    public var shadows: [Shadow] = []
    public var opacity: CGFloat = 1
    public init() {}
}

// MARK: - Text

public struct TextRun {
    public var string: String = ""
    public var fontName: String = "Helvetica"
    public var fontSize: CGFloat = 12
    public var color: Color = .black
    public var kerning: CGFloat = 0
    public var lineHeight: CGFloat = 0      // 0 == use the font's natural leading
    public var alignment: CTTextAlignment = .left
    public init() {}
}
