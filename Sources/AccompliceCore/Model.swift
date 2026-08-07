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

public enum BooleanOp: Int, Sendable, Hashable, CaseIterable {
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
    /// A locked layer ignores canvas clicks and drags — the layer list is the only
    /// way to select it, which is the whole point: it stays put while you work on
    /// top of it.
    public var isLocked = false
    public var opacity: CGFloat = 1
    public var booleanOp: BooleanOp = .none
    public var hasClippingMask = false
    public var breaksMaskChain = false
    /// The W/H padlock: edits and drags keep the aspect ratio while true.
    /// Locked by default — a loose resize that squashes artwork is the mistake,
    /// stretching on purpose is the exception you unlock for.
    public var constrainProportions = true

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

    /// Point types for a path layer, one per anchor.
    ///
    /// A CGPath has no idea what a point type is, so rebuilding a VectorPath from one
    /// can only guess from the geometry — and the guess is wrong in exactly the case
    /// that matters: an Aligned point whose handles happen to be the same length looks
    /// identical to a Mirrored one and comes back as Mirrored. Choosing the type has to
    /// stick, so it's stored.
    public var curveModes: [CurveMode] = []

    /// Corner radius for a path layer, in the layer's own units.
    ///
    /// Applied on the way out through Compose rather than baked into the stored path,
    /// so the corners stay sharp underneath and the number is one you can go back and
    /// change. Resizing the layer leaves it alone: a 12pt corner on a wider box is
    /// still a 12pt corner, which is what every other tool does and what you want.
    public var cornerRadius: CGFloat = 0
    public var cornerStyle: CornerStyle = .rounded

    /// Erase strokes for a bitmap layer, applied when it draws.
    ///
    /// Stored rather than burnt into the pixels: the same photo is used across several
    /// coins, and an erase you can't take back is a copy of the photo you didn't want
    /// to make.
    public var erased: [EraseStroke] = []

    /// Photo adjustments for a bitmap layer, applied at draw time — stored, like
    /// erases, so the pixels underneath are never touched.
    public var brightness: CGFloat = 0      // -1 … 1, 0 = untouched
    public var contrast: CGFloat = 1        // 0.25 … 4, 1 = untouched
    public var saturation: CGFloat = 1      // 0 … 2, 1 = untouched

    /// The visible region of a bitmap, in unit coordinates of the displayed image.
    /// Nil shows everything. Cropping is a window, not a knife.
    public var cropRect: CGRect?

    /// Perspective warp for a bitmap: where the four corners of the frame have
    /// been dragged to, in unit coordinates of the frame (top-left, top-right,
    /// bottom-right, bottom-left; y down). Nil means flat. Like every bitmap
    /// treatment here it's a stored decision — the pixels are never touched.
    public var warpCorners: [CGPoint]?

    /// True when any bitmap adjustment departs from neutral.
    public var hasBitmapAdjustments: Bool {
        brightness != 0 || contrast != 1 || saturation != 1 || cropRect != nil
    }

    /// The parameters a star or polygon was drawn from — Fireworks' Auto Shapes.
    ///
    /// The path is baked (so everything downstream just sees a path), but the recipe
    /// is kept so "make it a 7-point star" stays a number you can go back and change
    /// instead of a redraw.
    public var autoShape: AutoShape?

    public init(kind: LayerKind) { self.kind = kind }

    /// Regenerates a star or polygon path from its parameters, at the layer's size.
    public mutating func regenerateAutoShape() {
        guard let a = autoShape else { return }
        kind = .path(a.path(in: CGRect(origin: .zero, size: frame.size)), closed: true)
    }

    public var bounds: CGRect { frame }

    /// True when a visible child clips its siblings — the layer paints less than its
    /// frame says, and geometry shown to the user should come from
    /// `Compose.visibleBounds` instead.
    public var containsClippingMask: Bool {
        let kids: [Layer]
        switch kind {
        case .group(let k): kids = k
        case .shapeGroup(let k, _): kids = k
        default: return false
        }
        return kids.contains { ($0.hasClippingMask && $0.isVisible) || $0.containsClippingMask }
    }

    /// Anchor count for a path layer. What a model needs to tell an over-detailed
    /// trace from a shape that's meant to be intricate.
    public var pointCount: Int? {
        guard case .path(let cg, _) = kind else { return nil }
        var n = 0
        cg.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint, .addQuadCurveToPoint, .addCurveToPoint: n += 1
            default: break
            }
        }
        return n
    }

    /// Grows a curved text layer's frame to hold the whole ring.
    ///
    /// The arc is centred on the frame's centre, so a 400x70 text box can't contain a
    /// radius-200 circle — the glyphs land outside the layer and, inside an artboard
    /// that clips, vanish entirely while every command still reports success. Keeps
    /// the centre put, so curving text doesn't move it.
    public mutating func fitFrameToArc() {
        guard case .text(let run) = kind, let arc = run.arc else { return }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        // Radius to the baseline, plus room for the glyphs either side of it.
        let reach = arc.radius + run.fontSize * 1.5
        frame = CGRect(x: centre.x - reach, y: centre.y - reach,
                       width: reach * 2, height: reach * 2)
    }

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

    /// A copy with fresh ids throughout. Pasting or duplicating must not reuse ids —
    /// two layers answering to the same id would make selection and undo ambiguous.
    public func withNewIDs() -> Layer {
        var copy = self
        copy.id = UUID().uuidString
        switch kind {
        case .group(let k): copy.kind = .group(k.map { $0.withNewIDs() })
        case .shapeGroup(let k, let rule): copy.kind = .shapeGroup(k.map { $0.withNewIDs() }, rule)
        default: break
        }
        return copy
    }

    /// Every image key this layer or its children reference, so a copy can carry its
    /// assets to another document.
    public var imageRefs: Set<String> {
        switch kind {
        case .bitmap(let ref): return [ref]
        case .group(let k), .shapeGroup(let k, _):
            return k.reduce(into: Set<String>()) { $0.formUnion($1.imageRefs) }
        default: return []
        }
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

        // Erase strokes live in layer units, so they scale with the art. Leaving
        // them put is how a resized bitmap's holes drifted off their targets.
        if !erased.isEmpty {
            erased = erased.map { s in
                var t = s
                t.points = s.points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
                t.radius = s.radius * (sx + sy) / 2
                if let r = s.rect {
                    t.rect = CGRect(x: r.minX * sx, y: r.minY * sy,
                                    width: r.width * sx, height: r.height * sy)
                }
                return t
            }
        }

        // An artboard is a frame around work, not a container that owns its
        // size. Making it bigger gives you more room; it does not make the
        // drawing bigger. Sketch changed this and it is a large part of why
        // this app exists.
        if isArtboard {
            frame.size = newSize
            return
        }

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

    /// Accepts `#rgb`, `#rrggbb`, `#rrggbbaa` and any of those without the hash —
    /// all four turn up depending on where the colour was copied from. `alpha`
    /// applies only when the string doesn't carry its own.
    public init?(hex: String, alpha: CGFloat = 1) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard !s.isEmpty, s.allSatisfy(\.isHexDigit) else { return nil }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        let carriesAlpha = s.count == 8
        let shift: UInt32 = carriesAlpha ? 8 : 0
        func byte(_ n: UInt32) -> CGFloat { CGFloat((v >> (n + shift)) & 0xFF) / 255 }
        self.init(r: byte(16), g: byte(8), b: byte(0),
                  a: carriesAlpha ? CGFloat(v & 0xFF) / 255 : alpha)
    }

    /// Equal to the precision the file stores, so round-tripping a colour through the
    /// system colour panel doesn't read as an edit.
    public func matches(_ other: Color) -> Bool {
        func q(_ v: CGFloat) -> Int { Int((v * 1000).rounded()) }
        return q(r) == q(other.r) && q(g) == q(other.g) && q(b) == q(other.b) && q(a) == q(other.a)
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

/// How a stroke starts and ends, and what it does at a corner.
///
/// Butt and miter are CoreGraphics' defaults and what every stroke in the corpus
/// has always been drawn with, so they stay the default here — changing it would
/// redraw artwork that already exists. Line art wants round on both: every
/// fingertip in an icon is a round cap, and a miter join between two segments of
/// the same stroke shows up as a spike.
public enum LineCap: Int, Sendable { case butt = 0, round = 1, square = 2 }
public enum LineJoin: Int, Sendable { case miter = 0, round = 1, bevel = 2 }

public struct Border: Sendable {
    public var color: Color = .black
    public var thickness: CGFloat = 1
    public var position: BorderPosition = .center
    public var dashPattern: [CGFloat] = []
    public var cap: LineCap = .butt
    public var join: LineJoin = .miter
    public init() {}

    /// Sets both ends and corners from one word, which is how anyone describing a
    /// stroke thinks about it.
    public mutating func applyCap(_ name: String?) {
        switch name?.lowercased() {
        case "round": cap = .round; join = .round
        case "square", "projecting": cap = .square; join = .bevel
        case "butt", "flat": cap = .butt; join = .miter
        default: break
        }
    }
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

/// Text bent around a circle.
///
/// Deliberately an arc rather than attachment to an arbitrary path. Every curved
/// label Adam actually sets — the minute/hour/day rings on a coin — is a circle,
/// and text-on-path is fiddly to author and fiddlier to keep stable when the
/// string length changes. A radius and an angle are two numbers you can reason
/// about, and they survive an edit to the words.
public struct TextArc: Sendable, Equatable, Codable {
    /// Radius of the baseline circle, in layer units. The centre is the centre of
    /// the layer's frame.
    public var radius: CGFloat
    /// Where the string is centred, in degrees clockwise from 12 o'clock.
    public var angle: CGFloat = 0
    /// Run the text the other way round, glyphs inverted — what you want along the
    /// bottom of a coin so it reads the right way up.
    public var flipped: Bool = false

    public init(radius: CGFloat, angle: CGFloat = 0, flipped: Bool = false) {
        self.radius = radius
        self.angle = angle
        self.flipped = flipped
    }
}

/// A shape that remembers its recipe: star or polygon, ready to re-cook at a new
/// point count. Sides means points on a star.
public struct AutoShape: Sendable, Equatable {
    public var kind: Kind
    public var sides: Int
    /// Star only: inner radius as a fraction of the outer.
    public var innerRatio: CGFloat

    public enum Kind: String, Sendable { case star, polygon }

    public init(kind: Kind, sides: Int, innerRatio: CGFloat = 0.45) {
        self.kind = kind
        self.sides = max(3, sides)
        self.innerRatio = min(0.95, max(0.05, innerRatio))
    }

    /// Vertices around an ellipse inscribed in the rect, first point at 12 o'clock —
    /// which is how every star anyone draws is oriented.
    public func path(in rect: CGRect) -> CGPath {
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        let p = CGMutablePath()
        let outer = sides
        func vertex(_ angle: CGFloat, _ scale: CGFloat) -> CGPoint {
            CGPoint(x: cx + cos(angle) * rx * scale, y: cy + sin(angle) * ry * scale)
        }
        switch kind {
        case .polygon:
            for i in 0..<outer {
                let a = -CGFloat.pi / 2 + CGFloat(i) / CGFloat(outer) * 2 * .pi
                i == 0 ? p.move(to: vertex(a, 1)) : p.addLine(to: vertex(a, 1))
            }
        case .star:
            for i in 0..<(outer * 2) {
                let a = -CGFloat.pi / 2 + CGFloat(i) / CGFloat(outer * 2) * 2 * .pi
                let s: CGFloat = i.isMultiple(of: 2) ? 1 : innerRatio
                i == 0 ? p.move(to: vertex(a, s)) : p.addLine(to: vertex(a, s))
            }
        }
        p.closeSubpath()
        return p
    }
}

public struct TextRun: @unchecked Sendable {
    public var string: String = ""
    public var fontName: String = "Helvetica"
    public var fontSize: CGFloat = 12
    public var color: Color = .black
    public var kerning: CGFloat = 0
    /// Multiplier on the font's natural line height: 1 is single spaced, 1.5 is
    /// airy, 0 packs the lines on top of each other. Stored as a ratio rather
    /// than points so it survives a resize and reads the way CSS taught
    /// everyone to expect.
    public var lineHeight: CGFloat = 1
    public var alignment: CTTextAlignment = .left
    /// Straight text when nil, which is nearly all of it.
    public var arc: TextArc?
    /// Text following an arbitrary path, in the layer's own coordinates.
    ///
    /// Sketch's "text on path" is a text layer flagged
    /// automaticallyDrawOnUnderlyingPath sitting above a shape in the same group; the
    /// text runs along that shape. An arc can't express it in general — the path is
    /// whatever was drawn — so this carries the path itself.
    public var onPath: CGPath?
    public init() {}
}
