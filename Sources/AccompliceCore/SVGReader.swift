import CoreGraphics
import Foundation

// SVG in.
//
// Accomplice already writes SVG — this closes the loop so an exported file, or one
// from anywhere else, can be reopened and edited. Built on XMLParser and the existing
// PathParser, so there's one implementation of path-data syntax rather than two that
// drift.
//
// Scope is deliberate: shapes, groups, transforms, solid and gradient fills, strokes,
// and embedded images. Text is NOT converted to editable text — SVG text depends on
// fonts the file doesn't carry, and guessing produces something that looks right until
// it's engraved. Anything skipped is reported rather than silently dropped.

public final class SVGReader: NSObject {

    public struct Result {
        public var document: Document
        public var images: [String: Data]
        /// Things the file contained that we chose not to convert.
        public var warnings: [String]
    }

    public enum Failure: Error, CustomStringConvertible {
        case notSVG
        public var description: String { "not an SVG file, or it couldn't be parsed" }
    }

    // Parse state
    private var stack: [Frame] = []
    private var layers: [Layer] = []
    private var images: [String: Data] = [:]
    private var warnings: [String] = []
    private var viewBox: CGRect?
    private var declaredSize: CGSize?
    private var gradients: [String: Gradient] = [:]
    private var pendingGradientID: String?
    private var pendingStops: [(CGFloat, Color)] = []
    private var pendingGradientKind: GradientKind = .linear
    private var pendingGradientPoints: (from: CGPoint, to: CGPoint) = (.init(x: 0, y: 0), .init(x: 1, y: 0))
    private var depthSkipped = 0

    private struct Frame {
        var transform: CGAffineTransform
        var style: InheritedStyle
        var children: [Layer]
        var name: String
    }

    private struct InheritedStyle {
        var fill: String? = "#000000"
        var stroke: String?
        var strokeWidth: CGFloat = 1
        var opacity: CGFloat = 1
        var fillOpacity: CGFloat = 1
        var strokeOpacity: CGFloat = 1
        var dash: [CGFloat] = []
    }

    public func read(data: Data) throws -> Result {
        stack = [Frame(transform: .identity, style: InheritedStyle(), children: [], name: "root")]
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), let root = stack.first else { throw Failure.notSVG }

        var page = Page(name: "Page 1")
        page.layers = root.children
        guard !page.layers.isEmpty else { throw Failure.notSVG }

        var doc = Document()
        doc.sourceApp = "SVG"
        doc.pages = [page]
        return Result(document: doc, images: images, warnings: warnings)
    }

    public func read(url: URL) throws -> Result {
        try read(data: try Data(contentsOf: url))
    }

    // MARK: - Element handling

    fileprivate func begin(_ name: String, _ attrs: [String: String]) {
        if depthSkipped > 0 { depthSkipped += 1; return }

        switch name {
        case "svg":
            if let vb = attrs["viewBox"] {
                let n = SVGReader.numbers(vb)
                if n.count == 4 { viewBox = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
            }
            declaredSize = CGSize(width: SVGReader.length(attrs["width"]) ?? 0,
                                  height: SVGReader.length(attrs["height"]) ?? 0)
            push(attrs, name: "svg")

        case "g":
            push(attrs, name: attrs["id"] ?? "Group")

        case "linearGradient", "radialGradient":
            pendingGradientID = attrs["id"]
            pendingStops = []
            pendingGradientKind = name == "radialGradient" ? .radial : .linear
            let from = CGPoint(x: SVGReader.length(attrs["x1"]) ?? SVGReader.length(attrs["cx"]) ?? 0,
                               y: SVGReader.length(attrs["y1"]) ?? SVGReader.length(attrs["cy"]) ?? 0)
            let to = CGPoint(x: SVGReader.length(attrs["x2"]) ?? 1,
                             y: SVGReader.length(attrs["y2"]) ?? 0)
            pendingGradientPoints = (from, to)

        case "stop":
            let off = SVGReader.length(attrs["offset"]) ?? 0
            let c = SVGReader.color(attrs["stop-color"] ?? "#000000",
                                    alpha: SVGReader.length(attrs["stop-opacity"]) ?? 1) ?? .black
            pendingStops.append((off, c))

        case "path":
            guard let d = attrs["d"], !d.isEmpty else { return }
            emit(PathParser.path(from: d), attrs, defaultName: "Path")

        case "rect":
            let x = SVGReader.length(attrs["x"]) ?? 0, y = SVGReader.length(attrs["y"]) ?? 0
            let w = SVGReader.length(attrs["width"]) ?? 0, h = SVGReader.length(attrs["height"]) ?? 0
            guard w > 0, h > 0 else { return }
            let r = CGRect(x: x, y: y, width: w, height: h)
            let rx = SVGReader.length(attrs["rx"]) ?? SVGReader.length(attrs["ry"]) ?? 0
            let p = rx > 0 ? CGPath(roundedRect: r, cornerWidth: min(rx, w / 2),
                                    cornerHeight: min(rx, h / 2), transform: nil)
                           : CGPath(rect: r, transform: nil)
            emit(p, attrs, defaultName: "Rectangle")

        case "circle", "ellipse":
            let cx = SVGReader.length(attrs["cx"]) ?? 0, cy = SVGReader.length(attrs["cy"]) ?? 0
            let rx = SVGReader.length(attrs["r"]) ?? SVGReader.length(attrs["rx"]) ?? 0
            let ry = SVGReader.length(attrs["r"]) ?? SVGReader.length(attrs["ry"]) ?? 0
            guard rx > 0, ry > 0 else { return }
            let box = CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
            emit(CGPath(ellipseIn: box, transform: nil), attrs,
                 defaultName: name == "circle" ? "Circle" : "Oval")

        case "line":
            let p = CGMutablePath()
            p.move(to: CGPoint(x: SVGReader.length(attrs["x1"]) ?? 0, y: SVGReader.length(attrs["y1"]) ?? 0))
            p.addLine(to: CGPoint(x: SVGReader.length(attrs["x2"]) ?? 0, y: SVGReader.length(attrs["y2"]) ?? 0))
            emit(p.copy()!, attrs, defaultName: "Line", closed: false)

        case "polyline", "polygon":
            let n = SVGReader.numbers(attrs["points"] ?? "")
            guard n.count >= 4 else { return }
            let p = CGMutablePath()
            p.move(to: CGPoint(x: n[0], y: n[1]))
            var i = 2
            while i + 1 < n.count { p.addLine(to: CGPoint(x: n[i], y: n[i + 1])); i += 2 }
            if name == "polygon" { p.closeSubpath() }
            emit(p.copy()!, attrs, defaultName: name.capitalized, closed: name == "polygon")

        case "image":
            emitImage(attrs)

        case "text", "tspan":
            // See the note at the top: converting text without its font is a trap.
            if name == "text" { warnings.append("Text was skipped — SVG text needs fonts the file doesn't carry.") }
            depthSkipped = 1

        case "use":
            warnings.append("<use> references were skipped.")

        default:
            break
        }
    }

    fileprivate func end(_ name: String) {
        if depthSkipped > 0 { depthSkipped -= 1; return }
        switch name {
        case "svg", "g":
            guard stack.count > 1 else { return }
            let frame = stack.removeLast()
            guard !frame.children.isEmpty else { return }
            // A <g> becomes a group; the root <svg> just contributes its children.
            if name == "svg" {
                stack[stack.count - 1].children.append(contentsOf: frame.children)
            } else {
                let bounds = frame.children.map(\.frame).reduce(CGRect.null) { $0.union($1) }
                var g = Layer(kind: .group(frame.children.map { child in
                    var c = child
                    c.frame.origin = CGPoint(x: c.frame.minX - bounds.minX, y: c.frame.minY - bounds.minY)
                    return c
                }))
                g.name = frame.name
                g.frame = bounds.isNull ? .zero : bounds
                stack[stack.count - 1].children.append(g)
            }

        case "linearGradient", "radialGradient":
            if let id = pendingGradientID, !pendingStops.isEmpty {
                var g = Gradient()
                g.kind = pendingGradientKind
                g.from = pendingGradientPoints.from
                g.to = pendingGradientPoints.to
                g.stops = pendingStops
                gradients[id] = g
            }
            pendingGradientID = nil

        default:
            break
        }
    }

    // MARK: - Building layers

    private func push(_ attrs: [String: String], name: String) {
        let parent = stack[stack.count - 1]
        var t = parent.transform
        if let s = attrs["transform"] { t = SVGReader.transform(s).concatenating(t) }
        stack.append(Frame(transform: t,
                           style: inherited(attrs, from: parent.style),
                           children: [], name: name))
    }

    private func inherited(_ attrs: [String: String], from base: InheritedStyle) -> InheritedStyle {
        var s = base
        var a = attrs
        // A style="" attribute wins over presentation attributes, per the spec.
        if let style = attrs["style"] {
            for pair in style.split(separator: ";") {
                let kv = pair.split(separator: ":", maxSplits: 1)
                if kv.count == 2 {
                    a[kv[0].trimmingCharacters(in: .whitespaces)] =
                        kv[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if let v = a["fill"] { s.fill = v == "none" ? nil : v }
        if let v = a["stroke"] { s.stroke = v == "none" ? nil : v }
        if let v = SVGReader.length(a["stroke-width"]) { s.strokeWidth = v }
        if let v = SVGReader.length(a["opacity"]) { s.opacity = v }
        if let v = SVGReader.length(a["fill-opacity"]) { s.fillOpacity = v }
        if let v = SVGReader.length(a["stroke-opacity"]) { s.strokeOpacity = v }
        if let v = a["stroke-dasharray"], v != "none" { s.dash = SVGReader.numbers(v).filter { $0 > 0 } }
        return s
    }

    private func emit(_ path: CGPath, _ attrs: [String: String],
                      defaultName: String, closed: Bool = true) {
        let parent = stack[stack.count - 1]
        var t = parent.transform
        if let s = attrs["transform"] { t = SVGReader.transform(s).concatenating(t) }
        let world = path.transformed(by: t)
        let box = world.boundingBoxOfPath
        guard box.width.isFinite, box.height.isFinite, !box.isNull else { return }

        // Geometry is stored relative to the layer's own frame.
        let local = world.transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
        var l = Layer(kind: .path(local, closed: closed))
        l.name = attrs["id"] ?? defaultName
        l.frame = box
        l.style = style(from: inherited(attrs, from: parent.style), scale: t)
        if attrs["visibility"] == "hidden" || attrs["display"] == "none" { l.isVisible = false }
        stack[stack.count - 1].children.append(l)
    }

    private func style(from s: InheritedStyle, scale t: CGAffineTransform) -> Style {
        var out = Style()
        out.opacity = s.opacity
        if let f = s.fill {
            if let ref = SVGReader.gradientReference(f), let g = gradients[ref] {
                out.fills = [Fill(paint: .gradient(g))]
            } else if let c = SVGReader.color(f, alpha: s.fillOpacity) {
                out.fills = [Fill(paint: .color(c))]
            }
        }
        if let st = s.stroke, let c = SVGReader.color(st, alpha: s.strokeOpacity) {
            var b = Border()
            b.color = c
            // Stroke width is in user units, so a scaled group scales the stroke too.
            b.thickness = s.strokeWidth * sqrt(abs(t.a * t.d - t.b * t.c))
            b.dashPattern = s.dash
            out.borders = [b]
        }
        return out
    }

    private func emitImage(_ attrs: [String: String]) {
        let href = attrs["href"] ?? attrs["xlink:href"] ?? ""
        guard let comma = href.range(of: "base64,") else {
            warnings.append("An <image> linked to an external file and was skipped.")
            return
        }
        let b64 = String(href[comma.upperBound...]).filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: b64) else { return }

        let parent = stack[stack.count - 1]
        var t = parent.transform
        if let s = attrs["transform"] { t = SVGReader.transform(s).concatenating(t) }
        let w = SVGReader.length(attrs["width"]) ?? 0, h = SVGReader.length(attrs["height"]) ?? 0
        guard w > 0, h > 0 else { return }
        let box = CGRect(x: SVGReader.length(attrs["x"]) ?? 0, y: SVGReader.length(attrs["y"]) ?? 0,
                         width: w, height: h).applying(t)

        let key = "images/\(Zip.crc32(data))-\(data.count).png"
        images[key] = data
        var l = Layer(kind: .bitmap(imageRef: key))
        l.name = attrs["id"] ?? "Image"
        l.frame = box
        stack[stack.count - 1].children.append(l)
    }

    // MARK: - Value parsing

    static func numbers(_ s: String) -> [CGFloat] {
        var out: [CGFloat] = []
        var cur = ""
        for ch in s {
            if ch.isNumber || ch == "." || ch == "e" || ch == "E" {
                cur.append(ch)
            } else if ch == "-" || ch == "+" {
                if cur.isEmpty || cur.hasSuffix("e") || cur.hasSuffix("E") { cur.append(ch) }
                else { if let v = Double(cur) { out.append(CGFloat(v)) }; cur = String(ch) }
            } else {
                if let v = Double(cur) { out.append(CGFloat(v)) }
                cur = ""
            }
        }
        if let v = Double(cur) { out.append(CGFloat(v)) }
        return out
    }

    static func length(_ s: String?) -> CGFloat? {
        guard let s, !s.isEmpty else { return nil }
        if s.hasSuffix("%"), let v = Double(s.dropLast()) { return CGFloat(v / 100) }
        return numbers(s).first
    }

    static func gradientReference(_ s: String) -> String? {
        guard s.hasPrefix("url(") else { return nil }
        return s.dropFirst(4).drop(while: { $0 == "#" })
            .prefix(while: { $0 != ")" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    static func color(_ raw: String, alpha: CGFloat) -> Color? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "none" || s.hasPrefix("url(") { return nil }
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
            return Color(r: CGFloat((v >> 16) & 0xff) / 255,
                         g: CGFloat((v >> 8) & 0xff) / 255,
                         b: CGFloat(v & 0xff) / 255, a: alpha)
        }
        if s.hasPrefix("rgb") {
            let n = numbers(s)
            guard n.count >= 3 else { return nil }
            let scale: CGFloat = s.contains("%") ? 2.55 : 1
            return Color(r: n[0] * scale / 255, g: n[1] * scale / 255, b: n[2] * scale / 255,
                         a: n.count > 3 ? n[3] : alpha)
        }
        if let named = named[s] {
            return Color(r: named.0, g: named.1, b: named.2, a: alpha)
        }
        return nil
    }

    private static let named: [String: (CGFloat, CGFloat, CGFloat)] = [
        "black": (0, 0, 0), "white": (1, 1, 1), "red": (1, 0, 0), "green": (0, 0.5, 0),
        "blue": (0, 0, 1), "yellow": (1, 1, 0), "cyan": (0, 1, 1), "magenta": (1, 0, 1),
        "gray": (0.5, 0.5, 0.5), "grey": (0.5, 0.5, 0.5), "silver": (0.75, 0.75, 0.75),
        "maroon": (0.5, 0, 0), "olive": (0.5, 0.5, 0), "lime": (0, 1, 0),
        "navy": (0, 0, 0.5), "teal": (0, 0.5, 0.5), "purple": (0.5, 0, 0.5),
        "orange": (1, 0.65, 0),
    ]

    static func transform(_ s: String) -> CGAffineTransform {
        var t = CGAffineTransform.identity
        var scanner = s[...]
        while let open = scanner.firstIndex(of: "("), let close = scanner.firstIndex(of: ")") {
            let name = scanner[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\t"))
            let args = numbers(String(scanner[scanner.index(after: open)..<close]))
            var step = CGAffineTransform.identity
            switch name {
            case "translate":
                step = CGAffineTransform(translationX: args.first ?? 0, y: args.count > 1 ? args[1] : 0)
            case "scale":
                step = CGAffineTransform(scaleX: args.first ?? 1, y: args.count > 1 ? args[1] : (args.first ?? 1))
            case "rotate":
                let a = (args.first ?? 0) * .pi / 180
                if args.count >= 3 {
                    step = CGAffineTransform(translationX: args[1], y: args[2])
                        .rotated(by: a)
                        .translatedBy(x: -args[1], y: -args[2])
                } else {
                    step = CGAffineTransform(rotationAngle: a)
                }
            case "matrix":
                if args.count >= 6 {
                    step = CGAffineTransform(a: args[0], b: args[1], c: args[2],
                                             d: args[3], tx: args[4], ty: args[5])
                }
            case "skewx":
                step = CGAffineTransform(a: 1, b: 0, c: tan((args.first ?? 0) * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewy":
                step = CGAffineTransform(a: 1, b: tan((args.first ?? 0) * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default:
                break
            }
            t = step.concatenating(t)
            scanner = scanner[scanner.index(after: close)...]
        }
        return t
    }
}

extension SVGReader: XMLParserDelegate {
    public func parser(_ parser: XMLParser, didStartElement name: String,
                       namespaceURI: String?, qualifiedName qName: String?,
                       attributes: [String: String] = [:]) {
        begin(name.lowercased(), attributes)
    }

    public func parser(_ parser: XMLParser, didEndElement name: String,
                       namespaceURI: String?, qualifiedName qName: String?) {
        end(name.lowercased())
    }
}
