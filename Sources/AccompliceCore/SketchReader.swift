import CoreGraphics
import Foundation

// Reads a .sketch archive into our own model.
//
// Sketch stores every shape class (shapePath / rectangle / oval / star / polygon /
// triangle) as the same thing underneath: an array of `curvePoint`s in normalized
// 0..1 space within the layer frame. So there is exactly one path builder here, not six.

public struct SketchReader {

    public enum Failure: Error, CustomStringConvertible {
        case notSketch(String)
        public var description: String {
            switch self { case .notSketch(let s): return s }
        }
    }

    public private(set) var images: [String: Data] = [:]
    private var entries: [String: Data] = [:]

    public init() {}

    public mutating func read(url: URL) throws -> Document {
        entries = try Zip.read(url: url)
        guard let docData = entries["document.json"] else {
            throw Failure.notSketch("no document.json — is this a pre-2016 Sketch file? (those are SQLite or bundle format)")
        }
        images = entries.filter { $0.key.hasPrefix("images/") }

        var doc = Document()
        if let m = entries["meta.json"],
           let mj = try? JSONSerialization.jsonObject(with: m) as? [String: Any],
           let v = mj["appVersion"] as? String {
            doc.sourceApp = "Sketch \(v)"
        }

        // document.json lists pages in canvas order as file refs; fall back to
        // whatever pages/ contains if that list is missing or stale.
        var order: [String] = []
        if let dj = try? JSONSerialization.jsonObject(with: docData) as? [String: Any],
           let refs = dj["pages"] as? [[String: Any]] {
            order = refs.compactMap { $0["_ref"] as? String }.map { $0 + ".json" }
        }
        let available = entries.keys.filter { $0.hasPrefix("pages/") && $0.hasSuffix(".json") }
        for k in available.sorted() where !order.contains(k) { order.append(k) }

        for key in order {
            guard let d = entries[key],
                  let pj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            var page = Page(name: pj["name"] as? String ?? "Page")
            page.layers = (pj["layers"] as? [[String: Any]] ?? []).compactMap(layer(from:))
            doc.pages.append(page)
        }
        return doc
    }

    // MARK: - Layers

    private func layer(from j: [String: Any]) -> Layer? {
        let cls = j["_class"] as? String ?? ""
        let children = { (j["layers"] as? [[String: Any]] ?? []).compactMap(self.layer(from:)) }

        var kind: LayerKind
        switch cls {
        case "group", "artboard", "symbolMaster", "page":
            kind = .group(children())
        case "shapeGroup":
            kind = .shapeGroup(children(), WindingRule(rawValue: j["windingRule"] as? Int ?? 0) ?? .nonZero)
        case "shapePath", "rectangle", "oval", "star", "polygon", "triangle":
            let closed = j["isClosed"] as? Bool ?? true
            guard let p = path(from: j, closed: closed) else { return nil }
            kind = .path(p, closed: closed)
        case "text":
            kind = .text(textRun(from: j))
        case "bitmap":
            guard let ref = (j["image"] as? [String: Any])?["_ref"] as? String else { return nil }
            kind = .bitmap(imageRef: ref)
        case "slice", "hotspot", "symbolInstance", "MSImmutableHotspotLayer":
            return nil          // export helpers and UI-tool features we deliberately drop
        default:
            // Unknown container: keep its children rather than silently losing artwork.
            let kids = children()
            if kids.isEmpty { return nil }
            kind = .group(kids)
        }

        var l = Layer(kind: kind)
        l.id = j["do_objectID"] as? String ?? UUID().uuidString
        l.name = j["name"] as? String ?? cls
        l.frame = rect(j["frame"])
        l.rotation = num(j["rotation"]) ?? 0
        l.flipH = j["isFlippedHorizontal"] as? Bool ?? false
        l.flipV = j["isFlippedVertical"] as? Bool ?? false
        l.isVisible = j["isVisible"] as? Bool ?? true
        l.hasClippingMask = j["hasClippingMask"] as? Bool ?? false
        l.breaksMaskChain = j["shouldBreakMaskChain"] as? Bool ?? false
        l.booleanOp = BooleanOp(rawValue: j["booleanOperation"] as? Int ?? -1) ?? .none
        l.style = style(from: j["style"] as? [String: Any])
        if cls == "artboard" || cls == "symbolMaster" {
            l.isArtboard = true
            if j["hasBackgroundColor"] as? Bool ?? false {
                l.backgroundColor = color(j["backgroundColor"])
            }
        }
        return l
    }

    // MARK: - Geometry

    /// Builds the outline from Sketch's normalized curve points.
    ///
    /// Segment i→i+1 is a cubic whose control points are `points[i].curveFrom` and
    /// `points[i+1].curveTo`. Straight runs where a point carries a `cornerRadius`
    /// get filleted — that's how Sketch stores rounded rectangles.
    private func path(from j: [String: Any], closed: Bool) -> CGPath? {
        let raw = j["points"] as? [[String: Any]] ?? []
        guard raw.count >= 2 else { return nil }
        let f = rect(j["frame"])
        let w = f.width, h = f.height

        struct P { var pt: CGPoint; var from: CGPoint; var to: CGPoint; var hasFrom: Bool; var hasTo: Bool; var radius: CGFloat }
        let pts: [P] = raw.map { d in
            P(pt: point(d["point"], w, h),
              from: point(d["curveFrom"], w, h),
              to: point(d["curveTo"], w, h),
              hasFrom: d["hasCurveFrom"] as? Bool ?? false,
              hasTo: d["hasCurveTo"] as? Bool ?? false,
              radius: num(d["cornerRadius"]) ?? 0)
        }

        let path = CGMutablePath()
        let n = pts.count
        let segments = closed ? n : n - 1

        func isLine(_ i: Int, _ k: Int) -> Bool { !pts[i].hasFrom && !pts[k].hasTo }

        // Fillet radius is only meaningful where both neighbouring segments are straight.
        func fillet(_ i: Int) -> CGFloat {
            guard closed || (i > 0 && i < n - 1) else { return 0 }
            let prev = (i - 1 + n) % n, next = (i + 1) % n
            guard pts[i].radius > 0, isLine(prev, i), isLine(i, next) else { return 0 }
            let a = pts[prev].pt, b = pts[i].pt, c = pts[next].pt
            let d1 = hypot(b.x - a.x, b.y - a.y), d2 = hypot(c.x - b.x, c.y - b.y)
            return min(pts[i].radius, min(d1, d2) / 2)
        }

        func start(_ i: Int) -> CGPoint {
            let r = fillet(i)
            guard r > 0 else { return pts[i].pt }
            let next = (i + 1) % n
            let b = pts[i].pt, c = pts[next].pt
            let d = hypot(c.x - b.x, c.y - b.y)
            return d == 0 ? b : CGPoint(x: b.x + (c.x - b.x) / d * r, y: b.y + (c.y - b.y) / d * r)
        }
        func end(_ i: Int) -> CGPoint {
            let r = fillet(i)
            guard r > 0 else { return pts[i].pt }
            let prev = (i - 1 + n) % n
            let a = pts[prev].pt, b = pts[i].pt
            let d = hypot(b.x - a.x, b.y - a.y)
            return d == 0 ? b : CGPoint(x: b.x + (a.x - b.x) / d * r, y: b.y + (a.y - b.y) / d * r)
        }

        path.move(to: start(0))
        for s in 0..<segments {
            let i = s, k = (s + 1) % n
            let a = pts[i], b = pts[k]
            if a.hasFrom || b.hasTo {
                path.addCurve(to: pts[k].pt,
                              control1: a.hasFrom ? a.from : a.pt,
                              control2: b.hasTo ? b.to : b.pt)
            } else {
                let e = end(k)
                path.addLine(to: e)
                if fillet(k) > 0 { path.addQuadCurve(to: start(k), control: pts[k].pt) }
            }
        }
        if closed { path.closeSubpath() }
        return path.copy()
    }

    private func point(_ v: Any?, _ w: CGFloat, _ h: CGFloat) -> CGPoint {
        // Stored as the string "{0.5, 0.25}" — normalized to the layer frame.
        guard let s = v as? String else { return .zero }
        let parts = s.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return .zero }
        return CGPoint(x: CGFloat(parts[0]) * w, y: CGFloat(parts[1]) * h)
    }

    private func rect(_ v: Any?) -> CGRect {
        guard let d = v as? [String: Any] else { return .zero }
        return CGRect(x: num(d["x"]) ?? 0, y: num(d["y"]) ?? 0,
                      width: num(d["width"]) ?? 0, height: num(d["height"]) ?? 0)
    }

    private func num(_ v: Any?) -> CGFloat? {
        if let d = v as? Double { return CGFloat(d) }
        if let i = v as? Int { return CGFloat(i) }
        return nil
    }

    // MARK: - Style

    private func color(_ v: Any?) -> Color? {
        guard let d = v as? [String: Any] else { return nil }
        return Color(r: num(d["red"]) ?? 0, g: num(d["green"]) ?? 0,
                     b: num(d["blue"]) ?? 0, a: num(d["alpha"]) ?? 1)
    }

    private func style(from j: [String: Any]?) -> Style {
        var s = Style()
        guard let j else { return s }
        if let ctx = j["contextSettings"] as? [String: Any] { s.opacity = num(ctx["opacity"]) ?? 1 }

        for f in j["fills"] as? [[String: Any]] ?? [] {
            guard f["isEnabled"] as? Bool ?? true else { continue }
            let op = (f["contextSettings"] as? [String: Any]).flatMap { num($0["opacity"]) } ?? 1
            switch f["fillType"] as? Int ?? 0 {
            case 1:
                guard let g = f["gradient"] as? [String: Any] else { continue }
                var grad = Gradient()
                grad.kind = GradientKind(rawValue: g["gradientType"] as? Int ?? 0) ?? .linear
                grad.from = unitPoint(g["from"]); grad.to = unitPoint(g["to"])
                grad.stops = (g["stops"] as? [[String: Any]] ?? []).compactMap { st in
                    guard let c = color(st["color"]) else { return nil }
                    return (num(st["position"]) ?? 0, c)
                }
                if !grad.stops.isEmpty { s.fills.append(Fill(paint: .gradient(grad), opacity: op)) }
            case 0:
                if let c = color(f["color"]) { s.fills.append(Fill(paint: .color(c), opacity: op)) }
            default:
                continue   // pattern / noise fills: not in scope for v1
            }
        }

        for b in j["borders"] as? [[String: Any]] ?? [] {
            guard b["isEnabled"] as? Bool ?? true else { continue }
            var bd = Border()
            bd.color = color(b["color"]) ?? .black
            bd.thickness = num(b["thickness"]) ?? 1
            bd.position = BorderPosition(rawValue: b["position"] as? Int ?? 0) ?? .center
            if let opts = j["borderOptions"] as? [String: Any],
               let dash = opts["dashPattern"] as? [Any] {
                bd.dashPattern = dash.compactMap { num($0) }.filter { $0 > 0 }
            }
            s.borders.append(bd)
        }

        for sh in j["shadows"] as? [[String: Any]] ?? [] {
            guard sh["isEnabled"] as? Bool ?? true else { continue }
            var s2 = Shadow()
            s2.color = color(sh["color"]) ?? s2.color
            s2.offset = CGSize(width: num(sh["offsetX"]) ?? 0, height: num(sh["offsetY"]) ?? 0)
            s2.blur = num(sh["blurRadius"]) ?? 0
            s2.spread = num(sh["spread"]) ?? 0
            s.shadows.append(s2)
        }
        return s
    }

    private func unitPoint(_ v: Any?) -> CGPoint {
        guard let s = v as? String else { return .zero }
        let p = s.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return p.count == 2 ? CGPoint(x: p[0], y: p[1]) : .zero
    }

    // MARK: - Text

    private func textRun(from j: [String: Any]) -> TextRun {
        var t = TextRun()
        let attr = j["attributedString"] as? [String: Any]
        t.string = attr?["string"] as? String ?? ""

        // Take the first run's attributes. Mixed-run styling is rare in this corpus
        // and belongs in the editor, not the liberator.
        let attrs = (attr?["attributes"] as? [[String: Any]])?.first?["attributes"] as? [String: Any]
        if let fd = (attrs?["MSAttributedStringFontAttribute"] as? [String: Any])?["attributes"] as? [String: Any] {
            t.fontName = fd["name"] as? String ?? t.fontName
            t.fontSize = num(fd["size"]) ?? t.fontSize
        }
        if let c = color(attrs?["MSAttributedStringColorAttribute"]) { t.color = c }
        if let k = num(attrs?["kerning"]) { t.kerning = k }
        if let para = attrs?["paragraphStyle"] as? [String: Any] {
            t.lineHeight = num(para["maximumLineHeight"]) ?? 0
            switch para["alignment"] as? Int ?? 0 {
            case 1: t.alignment = .right
            case 2: t.alignment = .center
            case 3: t.alignment = .justified
            default: t.alignment = .left
            }
        }
        return t
    }
}
