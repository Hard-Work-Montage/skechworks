import CoreGraphics
import Foundation

// Writes .acmplc.png — a PNG with a ZIP appended.
//
// PNG readers stop at IEND; ZIP readers scan backwards for the end-of-central-directory
// record. So the same bytes are simultaneously a valid image (Finder thumbnails it,
// Preview opens it, anything can display it) and a valid archive (`unzip` gets your
// artwork out with no app installed).
//
// The Fireworks .fw.png trick, which is the single best idea anyone had about design
// file formats, and which nobody has shipped since 2013.
//
// Geometry is stored as SVG path data. Not because it's clever — because in twenty
// years someone with a text editor can still read it.

public struct AcmplcFile {

    public static let formatVersion = 1

    public struct Options: Sendable {
        public var coverPage: Int = 0
        public var coverSize: CGFloat = 1024
        public var includeExports = true
        public init() {}
    }

    public static func write(document: Document,
                             images: [String: Data],
                             options: Options = Options()) throws -> Data {

        let renderer = Renderer(images: images, background: Color(r: 1, g: 1, b: 1, a: 1))
        // Inside the archive, assets are guaranteed to sit next to the exports, so link
        // rather than embed — otherwise every page duplicates every bitmap it uses.
        let svg = SVGWriter(images: images, assetMode: .link(prefix: "../assets/"))

        // 1. The visible layer: a real render of the cover page.
        let coverIndex = min(max(0, options.coverPage), max(0, document.pages.count - 1))
        var coverPNG = Data()
        if !document.pages.isEmpty,
           let img = renderer.render(page: document.pages[coverIndex], maxDimension: options.coverSize),
           let d = Renderer.png(img) {
            coverPNG = d
        } else {
            coverPNG = blankPNG()
        }

        // 2. The payload.
        var entries: [ZipEntry] = []

        var pagesMeta: [[String: Any]] = []
        for (i, page) in document.pages.enumerated() {
            let slug = "\(String(format: "%03d", i))-\(slugify(page.name))"
            entries.append(ZipEntry(name: "pages/\(slug).json",
                                    data: try json(pageJSON(page))))
            if options.includeExports {
                entries.append(ZipEntry(name: "exports/\(slug).svg",
                                        data: Data(svg.svg(page: page).utf8)))
            }
            pagesMeta.append(["name": page.name, "file": "pages/\(slug).json",
                              "export": "exports/\(slug).svg", "layers": page.layers.count])
        }

        let doc: [String: Any] = [
            "format": "acmplc",
            "formatVersion": formatVersion,
            "generator": "Accomplice liberator",
            "importedFrom": document.sourceApp ?? "unknown",
            "coverPage": coverIndex,
            "pages": pagesMeta,
        ]
        entries.append(ZipEntry(name: "document.json", data: try json(doc)))

        for (k, v) in images {
            entries.append(ZipEntry(name: "assets/\(k)", data: v))
        }
        entries.append(ZipEntry(name: "README.txt", data: Data(readme(document, coverIndex).utf8)))

        // 3. Concatenate. Offsets are written relative to the PNG's length so the
        //    archive is internally consistent — no `zip -A` fixup needed afterwards.
        var out = coverPNG
        out.append(Zip.write(entries, offsetBase: coverPNG.count))
        return out
    }

    // MARK: - Clipboard

    /// Serializes layers plus any images they reference, so a copy survives being
    /// pasted into a different document.
    public static func encodeClipboard(layers: [Layer], images: [String: Data]) throws -> Data {
        var assets: [String: String] = [:]
        for key in layers.reduce(into: Set<String>(), { $0.formUnion($1.imageRefs) }) {
            if let d = images[key] { assets[key] = d.base64EncodedString() }
        }
        return try json(["format": "acmplc-clipboard",
                         "layers": layers.map(layerJSON),
                         "assets": assets])
    }

    public static func decodeClipboard(_ data: Data) -> (layers: [Layer], images: [String: Data])? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              j["format"] as? String == "acmplc-clipboard",
              let raw = j["layers"] as? [[String: Any]] else { return nil }
        var images: [String: Data] = [:]
        for (k, v) in j["assets"] as? [String: String] ?? [:] {
            if let d = Data(base64Encoded: v) { images[k] = d }
        }
        return (raw.compactMap(readLayer), images)
    }

    // MARK: - Reading

    public enum ReadError: Error, CustomStringConvertible {
        case stripped
        case malformed(String)
        public var description: String {
            switch self {
            case .stripped:
                return """
                    no document payload — this file's editable data was stripped, most \
                    likely by an image optimizer or a re-save from another image editor. \
                    The picture survives; the document does not.
                    """
            case .malformed(let s): return s
            }
        }
    }

    /// The extension every Accomplice document ends with.
    public static let suffix = "acmplc.png"

    /// The name without the compound extension: "Coin.acmplc.png" -> "Coin".
    public static func baseName(_ name: String) -> String {
        var base = name
        if base.lowercased().hasSuffix("." + suffix) {
            base = String(base.dropLast(suffix.count + 1))
        } else {
            for tail in [".png", ".acmplc"] where base.lowercased().hasSuffix(tail) {
                base = String(base.dropLast(tail.count))
            }
        }
        return base.isEmpty ? "Untitled" : base
    }

    /// Forces a filename back to `<name>.acmplc.png`.
    ///
    /// The save panel highlights "Untitled.acmplc" and leaves ".png" outside the
    /// selection, so typing a new name naturally produces "Coin.png". The bytes would
    /// still be a complete document — the payload is found by scanning, not by name —
    /// but the compound extension is what makes the file open in Accomplice rather than
    /// Preview, so it's put back.
    public static func normalisedName(_ name: String) -> String {
        var base = name
        if base.lowercased().hasSuffix("." + suffix) {
            return base
        }
        // Strip a trailing .png or .acmplc, in either order, then re-apply both.
        for tail in [".png", ".acmplc"] where base.lowercased().hasSuffix(tail) {
            base = String(base.dropLast(tail.count))
        }
        if base.lowercased().hasSuffix(".acmplc") { base = String(base.dropLast(7)) }
        if base.isEmpty { base = "Untitled" }
        return base + "." + suffix
    }

    public static func read(_ data: Data) throws -> (document: Document, images: [String: Data]) {
        let z: [String: Data]
        do { z = try Zip.read(data) } catch { throw ReadError.stripped }
        guard let docData = z["document.json"],
              let dj = try? JSONSerialization.jsonObject(with: docData) as? [String: Any] else {
            throw ReadError.stripped
        }

        var doc = Document()
        doc.sourceApp = dj["importedFrom"] as? String
        for entry in dj["pages"] as? [[String: Any]] ?? [] {
            guard let file = entry["file"] as? String, let pd = z[file],
                  let page = parsePage(pd) else { continue }
            doc.pages.append(page)
        }

        var images: [String: Data] = [:]
        for (k, v) in z where k.hasPrefix("assets/") {
            images[String(k.dropFirst("assets/".count))] = v
        }
        return (doc, images)
    }

    public static func read(url: URL) throws -> (document: Document, images: [String: Data]) {
        try read(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Parses one `pages/*.json` blob. Split out so `DocumentSource` can call it
    /// per page instead of the whole document being parsed at open time.
    public static func parsePage(_ data: Data) -> Page? {
        guard let pj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var page = Page(name: pj["name"] as? String ?? "Page")
        page.layers = (pj["layers"] as? [[String: Any]] ?? []).compactMap(readLayer)
        return page
    }

    private static func readLayer(_ j: [String: Any]) -> Layer? {
        let kids = { (j["layers"] as? [[String: Any]] ?? []).compactMap(readLayer) }
        let kind: LayerKind
        var modes: [CurveMode] = []
        var erased: [EraseStroke] = []
        switch j["type"] as? String ?? "" {
        case "group":
            kind = .group(kids())
        case "shapeGroup":
            kind = .shapeGroup(kids(), (j["windingRule"] as? String) == "evenodd" ? .evenOdd : .nonZero)
        case "path":
            guard let d = j["d"] as? String else { return nil }
            kind = .path(PathParser.path(from: d), closed: j["closed"] as? Bool ?? true)
            if let m = j["pointTypes"] as? [Int] {
                modes = m.compactMap { CurveMode(rawValue: $0) }
            }
        case "text":
            guard let t = j["text"] as? [String: Any] else { return nil }
            var run = TextRun()
            run.string = t["string"] as? String ?? ""
            run.fontName = t["font"] as? String ?? run.fontName
            run.fontSize = dbl(t["size"]) ?? run.fontSize
            run.kerning = dbl(t["kerning"]) ?? 0
            run.lineHeight = dbl(t["lineHeight"]) ?? 0
            if let hex = t["color"] as? String, let c = colorFrom(hex, 1) { run.color = c }
            if let a = t["arc"] as? [String: Any], let r = dbl(a["radius"]) {
                run.arc = TextArc(radius: r,
                                  angle: dbl(a["angle"]) ?? 0,
                                  flipped: a["flipped"] as? Bool ?? false)
            }
            switch t["align"] as? String {
            case "center": run.alignment = .center
            case "right": run.alignment = .right
            case "justified": run.alignment = .justified
            default: run.alignment = .left
            }
            kind = .text(run)
        case "bitmap":
            if let strokes = j["erased"] as? [[String: Any]] {
                erased = strokes.compactMap { e in
                    guard let pts = e["points"] as? [[Double]], let r = dbl(e["radius"]) else { return nil }
                    return EraseStroke(points: pts.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil },
                                       radius: r, softness: dbl(e["softness"]) ?? 0.5)
                }
            }
            guard let ref = j["image"] as? String else { return nil }
            kind = .bitmap(imageRef: ref.hasPrefix("assets/") ? String(ref.dropFirst(7)) : ref)
        default:
            return nil
        }

        var l = Layer(kind: kind)
        l.curveModes = modes
        l.erased = erased
        l.id = j["id"] as? String ?? UUID().uuidString
        l.name = j["name"] as? String ?? ""
        if let f = j["frame"] as? [String: Any] {
            l.frame = CGRect(x: dbl(f["x"]) ?? 0, y: dbl(f["y"]) ?? 0,
                             width: dbl(f["width"]) ?? 0, height: dbl(f["height"]) ?? 0)
        }
        l.rotation = dbl(j["rotation"]) ?? 0
        l.flipH = j["flipH"] as? Bool ?? false
        l.flipV = j["flipV"] as? Bool ?? false
        l.isVisible = j["visible"] as? Bool ?? true
        l.hasClippingMask = j["clippingMask"] as? Bool ?? false
        l.breaksMaskChain = j["breaksMaskChain"] as? Bool ?? false
        l.isArtboard = j["artboard"] as? Bool ?? false
        if let bg = j["background"] as? [String: Any], let hex = bg["color"] as? String {
            l.backgroundColor = colorFrom(hex, dbl(bg["alpha"]) ?? 1)
            l.backgroundInExport = bg["inExport"] as? Bool ?? true
        }
        switch j["boolean"] as? String {
        case "union": l.booleanOp = .union
        case "subtract": l.booleanOp = .subtract
        case "intersect": l.booleanOp = .intersect
        case "difference": l.booleanOp = .difference
        default: l.booleanOp = .none
        }
        l.style = readStyle(j["style"] as? [String: Any])
        return l
    }

    private static func readStyle(_ j: [String: Any]?) -> Style {
        var s = Style()
        guard let j else { return s }
        s.opacity = dbl(j["opacity"]) ?? 1
        for f in j["fills"] as? [[String: Any]] ?? [] {
            let alpha = dbl(f["alpha"]) ?? 1
            if (f["type"] as? String) == "gradient" {
                var g = Gradient()
                switch f["kind"] as? String {
                case "radial": g.kind = .radial
                case "angular": g.kind = .angular
                default: g.kind = .linear
                }
                if let p = f["from"] as? [Any], p.count == 2 { g.from = CGPoint(x: dbl(p[0]) ?? 0, y: dbl(p[1]) ?? 0) }
                if let p = f["to"] as? [Any], p.count == 2 { g.to = CGPoint(x: dbl(p[0]) ?? 0, y: dbl(p[1]) ?? 0) }
                g.stops = (f["stops"] as? [[String: Any]] ?? []).compactMap { st in
                    guard let hex = st["color"] as? String,
                          let c = colorFrom(hex, dbl(st["alpha"]) ?? 1) else { return nil }
                    return (dbl(st["at"]) ?? 0, c)
                }
                if !g.stops.isEmpty { s.fills.append(Fill(paint: .gradient(g))) }
            } else if let hex = f["color"] as? String, let c = colorFrom(hex, alpha) {
                s.fills.append(Fill(paint: .color(c)))
            }
        }
        for b in j["borders"] as? [[String: Any]] ?? [] {
            var bd = Border()
            if let hex = b["color"] as? String, let c = colorFrom(hex, 1) { bd.color = c }
            bd.thickness = dbl(b["width"]) ?? 1
            switch b["position"] as? String {
            case "inside": bd.position = .inside
            case "outside": bd.position = .outside
            default: bd.position = .center
            }
            bd.dashPattern = (b["dash"] as? [Any] ?? []).compactMap(dbl)
            s.borders.append(bd)
        }
        for sh in j["shadows"] as? [[String: Any]] ?? [] {
            var s2 = Shadow()
            if let hex = sh["color"] as? String, let c = colorFrom(hex, dbl(sh["alpha"]) ?? 1) { s2.color = c }
            s2.offset = CGSize(width: dbl(sh["dx"]) ?? 0, height: dbl(sh["dy"]) ?? 0)
            s2.blur = dbl(sh["blur"]) ?? 0
            s2.spread = dbl(sh["spread"]) ?? 0
            s.shadows.append(s2)
        }
        return s
    }

    private static func colorFrom(_ hex: String, _ alpha: CGFloat) -> Color? {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return Color(r: CGFloat((v >> 16) & 0xff) / 255,
                     g: CGFloat((v >> 8) & 0xff) / 255,
                     b: CGFloat(v & 0xff) / 255, a: alpha)
    }

    private static func dbl(_ v: Any?) -> CGFloat? {
        if let d = v as? Double { return CGFloat(d) }
        if let i = v as? Int { return CGFloat(i) }
        return nil
    }

    // MARK: - Serialization

    private static func pageJSON(_ p: Page) -> [String: Any] {
        ["name": p.name, "layers": p.layers.map(layerJSON)]
    }

    private static func layerJSON(_ l: Layer) -> [String: Any] {
        var d: [String: Any] = [
            "id": l.id, "name": l.name,
            "frame": ["x": l.frame.minX, "y": l.frame.minY,
                      "width": l.frame.width, "height": l.frame.height],
            "visible": l.isVisible,
        ]
        if l.rotation != 0 { d["rotation"] = l.rotation }
        if l.flipH { d["flipH"] = true }
        if l.flipV { d["flipV"] = true }
        if l.booleanOp != .none { d["boolean"] = boolName(l.booleanOp) }
        if l.hasClippingMask { d["clippingMask"] = true }
        if l.breaksMaskChain { d["breaksMaskChain"] = true }
        if l.isArtboard { d["artboard"] = true }
        if let bg = l.backgroundColor {
            d["background"] = ["color": bg.hex, "alpha": bg.a, "inExport": l.backgroundInExport]
        }
        if let s = styleJSON(l.style) { d["style"] = s }

        let w = SVGWriter()
        switch l.kind {
        case .group(let kids):
            d["type"] = "group"; d["layers"] = kids.map(layerJSON)
        case .shapeGroup(let kids, let rule):
            // No baked `resolved` outline here: it's a cache, fully derivable from the
            // children, and caches don't belong in an archival format. exports/ already
            // carries the final geometry for anyone who just wants the shape.
            d["type"] = "shapeGroup"
            d["windingRule"] = rule == .evenOdd ? "evenodd" : "nonzero"
            d["layers"] = kids.map(layerJSON)
        case .path(let p, let closed):
            d["type"] = "path"; d["closed"] = closed; d["d"] = w.pathData(p)
            if !l.curveModes.isEmpty { d["pointTypes"] = l.curveModes.map(\.rawValue) }
        case .text(let t):
            d["type"] = "text"
            let align: String
            switch t.alignment {
            case .center: align = "center"
            case .right: align = "right"
            case .justified: align = "justified"
            default: align = "left"
            }
            var text: [String: Any] = ["string": t.string, "font": t.fontName, "size": t.fontSize,
                                       "color": t.color.hex, "kerning": t.kerning,
                                       "lineHeight": t.lineHeight, "align": align]
            if let a = t.arc {
                text["arc"] = ["radius": a.radius, "angle": a.angle, "flipped": a.flipped]
            }
            d["text"] = text
        case .bitmap(let ref):
            d["type"] = "bitmap"; d["image"] = "assets/\(ref)"
            if !l.erased.isEmpty {
                d["erased"] = l.erased.map { e in
                    ["points": e.points.map { [$0.x, $0.y] },
                     "radius": e.radius, "softness": e.softness] as [String: Any]
                }
            }
        }
        return d
    }

    private static func styleJSON(_ s: Style) -> [String: Any]? {
        var d: [String: Any] = [:]
        if s.opacity != 1 { d["opacity"] = s.opacity }
        if !s.fills.isEmpty {
            d["fills"] = s.fills.map { f -> [String: Any] in
                switch f.paint {
                case .color(let c): return ["type": "color", "color": c.hex, "alpha": c.a * f.opacity]
                case .gradient(let g):
                    return ["type": "gradient",
                            "kind": ["linear", "radial", "angular"][g.kind.rawValue],
                            "from": [g.from.x, g.from.y], "to": [g.to.x, g.to.y],
                            "stops": g.stops.map { ["at": $0.position, "color": $0.color.hex, "alpha": $0.color.a] }]
                }
            }
        }
        if !s.borders.isEmpty {
            d["borders"] = s.borders.map { b -> [String: Any] in
                var o: [String: Any] = ["color": b.color.hex, "width": b.thickness,
                                        "position": ["center", "inside", "outside"][b.position.rawValue]]
                if !b.dashPattern.isEmpty { o["dash"] = b.dashPattern }
                return o
            }
        }
        if !s.shadows.isEmpty {
            d["shadows"] = s.shadows.map { ["color": $0.color.hex, "alpha": $0.color.a,
                                            "dx": $0.offset.width, "dy": $0.offset.height,
                                            "blur": $0.blur, "spread": $0.spread] }
        }
        return d.isEmpty ? nil : d
    }

    private static func boolName(_ b: BooleanOp) -> String {
        ["none", "union", "subtract", "intersect", "difference"][b.rawValue + 1]
    }

    private static func json(_ o: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func slugify(_ s: String) -> String {
        let ok = s.lowercased().map { c -> Character in
            (c.isLetter || c.isNumber) ? c : "-"
        }
        let joined = String(ok).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "page" : String(joined.prefix(48))
    }

    private static func readme(_ d: Document, _ cover: Int) -> String {
        """
        This file is an Accomplice document (.acmplc.png).

        It is two things at once, on purpose:

          1. A valid PNG. Double-click it. Any image viewer, on any operating
             system, will show you page \(cover + 1) of this document.

          2. A valid ZIP. Rename it to .zip, or run:  unzip <thisfile>

        Inside the ZIP:

          exports/     Every page as an SVG. This is your artwork. Open these in
                       any vector program, or send them straight to a cutter.
          pages/       The editable document, as JSON. Geometry is stored using
                       SVG path syntax, so it is readable without any tooling.
          assets/      Placed images, exactly as they were embedded.
          document.json  Page order and metadata.

        You do not need Accomplice to get your work back out of this file. That is
        the entire point. If this program disappears tomorrow, unzip it and your
        artwork is still there, in a format that has outlived several companies.

        Imported from: \(d.sourceApp ?? "unknown")
        Pages: \(d.pages.count)

        One caution: the editable data lives in bytes appended after the PNG. If
        you run this file through an image optimizer or re-save it from another
        image editor, that data is stripped and you will be left with only the
        picture. Keep your originals.
        """
    }

    private static func blankPNG() -> Data {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage().flatMap(Renderer.png) ?? Data()
    }
}
