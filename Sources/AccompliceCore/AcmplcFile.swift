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

    public struct Options {
        public var coverPage: Int = 0
        public var coverSize: CGFloat = 1024
        public var includeExports = true
        public init() {}
    }

    public static func write(document: Document,
                             images: [String: Data],
                             options: Options = Options()) throws -> Data {

        let renderer = Renderer(images: images, background: Color(r: 1, g: 1, b: 1, a: 1))
        let svg = SVGWriter(images: images)

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
        if let s = styleJSON(l.style) { d["style"] = s }

        let w = SVGWriter()
        switch l.kind {
        case .group(let kids):
            d["type"] = "group"; d["layers"] = kids.map(layerJSON)
        case .shapeGroup(let kids, let rule):
            d["type"] = "shapeGroup"
            d["windingRule"] = rule == .evenOdd ? "evenodd" : "nonzero"
            d["layers"] = kids.map(layerJSON)
            if let p = Compose.resolvedPath(l) { d["resolved"] = w.pathData(p) }
        case .path(let p, let closed):
            d["type"] = "path"; d["closed"] = closed; d["d"] = w.pathData(p)
        case .text(let t):
            d["type"] = "text"
            d["text"] = ["string": t.string, "font": t.fontName, "size": t.fontSize,
                         "color": t.color.hex, "kerning": t.kerning, "lineHeight": t.lineHeight]
        case .bitmap(let ref):
            d["type"] = "bitmap"; d["image"] = "assets/\(ref)"
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
