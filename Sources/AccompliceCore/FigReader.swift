import CoreGraphics
import Foundation

/// Turning a decoded .fig into a document.
///
/// Figma sends a flat list of node changes rather than a tree: each carries its
/// own guid and the guid of its parent, plus a `position` string that orders
/// siblings. So the tree is rebuilt here rather than read.
///
/// Geometry arrives as an index into the file's blobs, in Figma's own path
/// encoding — a byte per command followed by float pairs. That much is not in
/// the schema and had to be read off a real file, so it's the one part of this
/// that can go stale. Everything else is named by the schema the file carries.
public struct FigReader {

    public private(set) var images: [String: Data] = [:]
    public private(set) var warnings: [String] = []

    public init() {}

    public mutating func read(url: URL) throws -> Document {
        let unpacked = try FigFile.unpack(url: url)
        // A .fig is a zip when it carries bitmaps, and those are the bitmaps.
        if let entries = try? Zip.read(url: url) {
            for (name, bytes) in entries where name.hasPrefix("images/") {
                images["images/\(Zip.crc32(bytes))-\(bytes.count).png"] = bytes
            }
        }
        return try build(unpacked)
    }

    public mutating func read(data: Data) throws -> Document {
        try build(try FigFile.unpack(data: data))
    }

    // MARK: - Assembling

    private struct Node {
        var value: Kiwi.Value
        var id: String
        var parent: String?
        var order: String
    }

    private mutating func build(_ unpacked: FigFile.Unpacked) throws -> Document {
        guard let root = unpacked.document.fields,
              let changes = root["nodeChanges"]?.items else { throw FigFile.Failure.noDocument }
        let blobs = (root["blobs"]?.items ?? []).map { bytes(of: $0) }

        var nodes: [Node] = []
        for c in changes {
            guard let id = guid(c["guid"]) else { continue }
            nodes.append(Node(value: c, id: id, parent: guid(c["parentIndex"]?["guid"]),
                              order: c["parentIndex"]?["position"]?.text ?? ""))
        }
        var children: [String: [Node]] = [:]
        for n in nodes where n.parent != nil { children[n.parent!, default: []].append(n) }
        // Figma orders siblings with a fractional-index string, so plain string
        // order is the right order. Sorting by it beats trusting the file's own
        // sequence, which is a change log rather than a drawing.
        for k in children.keys { children[k]?.sort { $0.order < $1.order } }

        var doc = Document()
        guard let document = nodes.first(where: { $0.value["type"]?.text == "DOCUMENT" }) else {
            throw FigFile.Failure.noDocument
        }
        for canvas in children[document.id] ?? [] {
            guard canvas.value["type"]?.text == "CANVAS" else { continue }
            var page = Page(name: canvas.value["name"]?.text ?? "Page")
            page.layers = (children[canvas.id] ?? []).compactMap { layer(from: $0, children: children, blobs: blobs) }
            // Figma pages have no bounds and can sit anywhere, including well
            // into negative space. Everything shifts so the artwork starts near
            // the origin, which is where a canvas expects to find it.
            let box = page.layers.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            if !box.isNull, box.minX != 0 || box.minY != 0 {
                for i in page.layers.indices {
                    page.layers[i].frame.origin.x -= box.minX
                    page.layers[i].frame.origin.y -= box.minY
                }
            }
            doc.pages.append(page)
        }
        if doc.pages.isEmpty { doc.pages = [Page(name: "Page 1")] }
        return doc
    }

    private mutating func layer(from node: Node, children: [String: [Node]],
                                blobs: [Data]) -> Layer? {
        let v = node.value
        let type = v["type"]?.text ?? ""
        let name = v["name"]?.text ?? type.capitalized
        let size = CGSize(width: v["size"]?["x"]?.number ?? 0, height: v["size"]?["y"]?.number ?? 0)
        let at = CGPoint(x: v["transform"]?["m02"]?.number ?? 0, y: v["transform"]?["m12"]?.number ?? 0)

        var made: Layer?
        switch type {
        case "CANVAS", "DOCUMENT":
            return nil

        case "FRAME", "GROUP", "SECTION", "COMPONENT", "INSTANCE":
            let kids = (children[node.id] ?? []).compactMap { layer(from: $0, children: children, blobs: blobs) }
            var l = Layer(kind: .group(kids))
            // A frame is the closest thing Figma has to an artboard, and the
            // thing a person will expect to find one.
            l.isArtboard = (type == "FRAME" || type == "SECTION")
            if l.isArtboard { l.backgroundColor = colour(v["fillPaints"]?.items?.first) ?? Color(r: 1, g: 1, b: 1, a: 1) }
            l.frame = CGRect(origin: at, size: size)
            l.name = name
            made = l

        case "TEXT":
            // The words are here; the typesetting is not. Figma stores runs,
            // fonts and layout in its own tables, so this brings across a text
            // layer with the right words at the right size and says so.
            var run = TextRun()
            run.string = v["textData"]?["characters"]?.text ?? name
            run.fontSize = v["fontSize"]?.number.map { CGFloat($0) } ?? 16
            run.color = colour(v["fillPaints"]?.items?.first) ?? .black
            var l = Layer(kind: .text(run))
            l.frame = CGRect(origin: at, size: size)
            l.name = name
            warnings.append("Text “\(name)” came across as plain text; Figma's typesetting didn't.")
            made = l

        default:
            guard let path = geometry(v["fillGeometry"], blobs: blobs)
                    ?? geometry(v["strokeGeometry"], blobs: blobs) else { return nil }
            var l = Layer(kind: .path(path, closed: true))
            l.frame = CGRect(origin: at, size: size)
            l.name = name
            if let fill = colour(v["fillPaints"]?.items?.first) {
                l.style.fills = [Fill(paint: .color(fill))]
            }
            if let stroke = colour(v["strokePaints"]?.items?.first) {
                var b = Border()
                b.color = stroke
                b.thickness = v["strokeWeight"]?.number.map { CGFloat($0) } ?? 1
                l.style.borders = [b]
            }
            made = l
        }

        guard var l = made else { return nil }
        l.isVisible = v["visible"]?.number.map { $0 != 0 } ?? true
        l.style.opacity = v["opacity"]?.number.map { CGFloat($0) } ?? 1
        return l
    }

    // MARK: - Geometry

    /// Figma's path encoding: a command byte, then that command's points as
    /// little-endian float pairs.
    ///
    /// Not described by the schema — the schema says "here are some bytes" — so
    /// this was read off real files: a rectangle whose lineTos land exactly on
    /// its own 310×278, and an ellipse whose curves come back a circle.
    static func path(from bytes: Data) -> CGPath? {
        guard !bytes.isEmpty else { return nil }
        let p = CGMutablePath()
        var i = bytes.startIndex
        var started = false

        func float() -> CGFloat? {
            guard i + 4 <= bytes.endIndex else { return nil }
            let v = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8
                | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            i += 4
            return CGFloat(Float(bitPattern: v))
        }
        func point() -> CGPoint? {
            guard let x = float(), let y = float() else { return nil }
            return CGPoint(x: x, y: y)
        }

        while i < bytes.endIndex {
            let command = bytes[i]
            i += 1
            switch command {
            case 1:
                guard let a = point() else { return started ? p : nil }
                p.move(to: a); started = true
            case 2:
                guard started, let a = point() else { return started ? p : nil }
                p.addLine(to: a)
            case 3:
                guard started, let c = point(), let a = point() else { return started ? p : nil }
                p.addQuadCurve(to: a, control: c)
            case 4:
                guard started, let c1 = point(), let c2 = point(), let a = point() else {
                    return started ? p : nil
                }
                p.addCurve(to: a, control1: c1, control2: c2)
            case 5:
                p.closeSubpath()
            default:
                // An unknown command can't be skipped — nothing says how many
                // numbers belong to it — so the path ends here rather than
                // reading coordinates out of whatever came next.
                return started ? p : nil
            }
        }
        return started ? p : nil
    }

    private func geometry(_ value: Kiwi.Value?, blobs: [Data]) -> CGPath? {
        guard let items = value?.items, !items.isEmpty else { return nil }
        let combined = CGMutablePath()
        var any = false
        for g in items {
            guard let index = g["commandsBlob"]?.number.map(Int.init),
                  index >= 0, index < blobs.count,
                  let piece = Self.path(from: blobs[index]) else { continue }
            combined.addPath(piece)
            any = true
        }
        return any ? combined : nil
    }

    // MARK: - Bits and pieces

    private func guid(_ v: Kiwi.Value?) -> String? {
        guard let g = v?.fields,
              let session = g["sessionID"]?.number, let local = g["localID"]?.number else { return nil }
        return "\(Int(session)):\(Int(local))"
    }

    private func colour(_ paint: Kiwi.Value?) -> Color? {
        guard let paint, paint["type"]?.text == "SOLID", let c = paint["color"]?.fields else { return nil }
        let opacity = paint["opacity"]?.number ?? 1
        return Color(r: CGFloat(c["r"]?.number ?? 0), g: CGFloat(c["g"]?.number ?? 0),
                     b: CGFloat(c["b"]?.number ?? 0),
                     a: CGFloat((c["a"]?.number ?? 1) * opacity))
    }

    private func bytes(of blob: Kiwi.Value) -> Data {
        guard let v = blob["bytes"] else { return Data() }
        switch v {
        case .array(let a): return Data(a.compactMap { if case .byte(let b) = $0 { return b }; return nil })
        case .string(let s): return Data(s.utf8)
        default: return Data()
        }
    }
}
