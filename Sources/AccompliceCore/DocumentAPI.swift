import CoreGraphics
import Foundation

// The scriptable surface.
//
// This exists so plugins and a language model drive the document through ONE
// vocabulary, and so every operation lands on the same undo stack a human's would.
// Building it before wiring up a model is deliberate: a model that pokes at internals
// produces changes you can't inspect, can't undo, and can't reproduce.
//
// The shape is chosen for a model's benefit — flat JSON, named operations, a query
// instead of layer ids. Ids are UUIDs; asking a model to copy them accurately is a
// waste of its attention and a source of silent mistakes. It describes what it wants
// ("every path filled black") and the app resolves that itself.

// MARK: - Finding layers

public struct LayerQuery: Codable, Sendable {
    /// Case-insensitive substring of the layer name.
    public var name: String?
    /// "path", "text", "image", "group", "artboard", "shapeGroup"
    public var type: String?
    /// Hex, e.g. "#000000". Matches a layer whose first fill is this colour.
    public var fill: String?
    /// Hex of a border colour.
    public var stroke: String?
    /// Substring of a text layer's content.
    public var text: String?
    public var visible: Bool?
    /// Layers whose name matches nothing else — useful for cleanup.
    public var minWidth: Double?
    public var maxWidth: Double?
    /// Restrict to the current selection.
    public var selectedOnly: Bool?
    /// Cap the result, so a mistaken query can't rewrite a whole document.
    public var limit: Int?

    public init() {}

    var isEmpty: Bool {
        name == nil && type == nil && fill == nil && stroke == nil && text == nil
            && visible == nil && minWidth == nil && maxWidth == nil && selectedOnly == nil
    }
}

extension Layer {
    var apiType: String {
        switch kind {
        case .group: return isArtboard ? "artboard" : "group"
        case .shapeGroup: return "shapeGroup"
        case .path: return "path"
        case .text: return "text"
        case .bitmap: return "image"
        }
    }

    var apiText: String? {
        if case .text(let t) = kind { return t.string }
        return nil
    }

    var firstFillHex: String? {
        guard case .color(let c)? = style.fills.first?.paint else { return nil }
        return c.hex
    }

    func matches(_ q: LayerQuery) -> Bool {
        if let n = q.name, !name.localizedCaseInsensitiveContains(n) { return false }
        if let t = q.type, apiType.lowercased() != t.lowercased() { return false }
        if let f = q.fill, firstFillHex?.lowercased() != f.lowercased() { return false }
        if let s = q.stroke, style.borders.first?.color.hex.lowercased() != s.lowercased() { return false }
        if let t = q.text {
            guard let content = apiText, content.localizedCaseInsensitiveContains(t) else { return false }
        }
        if let v = q.visible, isVisible != v { return false }
        if let w = q.minWidth, Double(frame.width) < w { return false }
        if let w = q.maxWidth, Double(frame.width) > w { return false }
        return true
    }
}

extension Page {
    /// Every layer matching a query, outermost first.
    public func find(_ q: LayerQuery, selection: Set<String> = []) -> [String] {
        var out: [String] = []
        func walk(_ ls: [Layer]) {
            for l in ls {
                let inScope = (q.selectedOnly != true) || selection.contains(l.id)
                if inScope && l.matches(q) { out.append(l.id) }
                switch l.kind {
                case .group(let k), .shapeGroup(let k, _): walk(k)
                default: continue
                }
            }
        }
        walk(layers)
        if let limit = q.limit, out.count > limit { out = Array(out.prefix(limit)) }
        return out
    }

    /// A compact description for a model's context.
    ///
    /// Deliberately lossy: nesting, names, types, sizes and fills — enough to reason
    /// about, small enough not to swamp the window. Geometry is summarised, never
    /// dumped; a coin page is 900,000 curve points.
    public func describe(maxLayers: Int = 200) -> String {
        var lines: [String] = ["page: \(name)"]
        var count = 0
        func walk(_ ls: [Layer], _ depth: Int) {
            for l in ls {
                guard count < maxLayers else { return }
                count += 1
                var bits = ["\(String(repeating: "  ", count: depth))- \(l.apiType) “\(l.name)”"]
                bits.append("\(Int(l.frame.width))×\(Int(l.frame.height))")
                bits.append("at \(Int(l.frame.minX)),\(Int(l.frame.minY))")
                if let f = l.firstFillHex { bits.append("fill \(f)") }
                if let b = l.style.borders.first { bits.append("stroke \(b.color.hex) \(Int(b.thickness))pt") }
                if !l.isVisible { bits.append("hidden") }
                if let t = l.apiText { bits.append("text: \(t.replacingOccurrences(of: "\n", with: " ").prefix(40))") }
                lines.append(bits.joined(separator: " · "))
                switch l.kind {
                case .group(let k), .shapeGroup(let k, _): walk(k, depth + 1)
                default: continue
                }
            }
        }
        walk(layers, 0)
        if count >= maxLayers { lines.append("… truncated at \(maxLayers) layers") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Operations

/// One scripted change. Every case maps onto something a human could do in the UI,
/// which is what keeps undo and the model honest.
public enum DocumentCommand: Sendable {
    case select(LayerQuery)
    case delete(LayerQuery)
    case setFill(LayerQuery, hex: String)
    case setStroke(LayerQuery, hex: String, width: Double?)
    case setOpacity(LayerQuery, value: Double)
    case setVisible(LayerQuery, value: Bool)
    case rename(LayerQuery, pattern: String)
    case move(LayerQuery, dx: Double, dy: Double)
    case resize(LayerQuery, width: Double?, height: Double?)
    case align(LayerQuery, edge: String)
    case distribute(LayerQuery, axis: String)
    case order(LayerQuery, where: String)   // front | back | forward | backward
    case group(LayerQuery, name: String?)
    case ungroup(LayerQuery)

    public var query: LayerQuery {
        switch self {
        case .select(let q), .delete(let q), .ungroup(let q): return q
        case .setFill(let q, _), .setOpacity(let q, _), .setVisible(let q, _): return q
        case .setStroke(let q, _, _), .rename(let q, _), .align(let q, _): return q
        case .move(let q, _, _), .resize(let q, _, _): return q
        case .distribute(let q, _), .order(let q, _), .group(let q, _): return q
        }
    }

    /// Human-readable, and used as the undo action name.
    public var summary: String {
        switch self {
        case .select: return "Select"
        case .delete: return "Delete"
        case .setFill(_, let hex): return "Set Fill \(hex)"
        case .setStroke(_, let hex, _): return "Set Stroke \(hex)"
        case .setOpacity(_, let v): return "Set Opacity \(Int(v * 100))%"
        case .setVisible(_, let v): return v ? "Show" : "Hide"
        case .rename: return "Rename"
        case .move: return "Move"
        case .resize: return "Resize"
        case .align(_, let e): return "Align \(e)"
        case .distribute(_, let a): return "Distribute \(a)"
        case .order(_, let w): return "Order \(w)"
        case .group: return "Group"
        case .ungroup: return "Ungroup"
        }
    }
}

// MARK: - JSON

extension DocumentCommand {

    /// Decodes `{"op": "...", ...}`. Written by hand rather than derived so the wire
    /// format stays flat and obvious — a model writes this, and every nested
    /// discriminator is another thing for it to get subtly wrong.
    public static func decode(_ any: Any) -> DocumentCommand? {
        guard let d = any as? [String: Any], let op = d["op"] as? String else { return nil }
        let q = decodeQuery(d)
        func s(_ k: String) -> String? { d[k] as? String }
        func n(_ k: String) -> Double? {
            if let v = d[k] as? Double { return v }
            if let v = d[k] as? Int { return Double(v) }
            return nil
        }

        switch op.lowercased() {
        case "select": return .select(q)
        case "delete": return .delete(q)
        case "setfill", "fill": return s("hex").map { .setFill(q, hex: $0) }
        case "setstroke", "stroke": return s("hex").map { .setStroke(q, hex: $0, width: n("width")) }
        case "setopacity", "opacity":
            guard let v = n("value") else { return nil }
            return .setOpacity(q, value: v > 1 ? v / 100 : v)   // accept 50 or 0.5
        case "setvisible", "show", "hide":
            let v = (d["value"] as? Bool) ?? (op.lowercased() == "show")
            return .setVisible(q, value: v)
        case "rename": return s("pattern").map { .rename(q, pattern: $0) }
        case "move": return .move(q, dx: n("dx") ?? 0, dy: n("dy") ?? 0)
        case "resize": return .resize(q, width: n("width"), height: n("height"))
        case "align": return s("edge").map { .align(q, edge: $0) }
        case "distribute": return .distribute(q, axis: s("axis") ?? "horizontal")
        case "order", "arrange": return .order(q, where: s("where") ?? "front")
        case "group": return .group(q, name: s("name"))
        case "ungroup": return .ungroup(q)
        default: return nil
        }
    }

    public static func decodeList(_ data: Data) -> [DocumentCommand] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let arr = root as? [Any] { return arr.compactMap(decode) }
        if let obj = root as? [String: Any] {
            if let arr = obj["commands"] as? [Any] { return arr.compactMap(decode) }
            return [decode(obj)].compactMap { $0 }
        }
        return []
    }

    private static func decodeQuery(_ d: [String: Any]) -> LayerQuery {
        var q = LayerQuery()
        // Accept either a nested "where" object or the fields inline, because models
        // produce both and rejecting one is a pointless round trip.
        let src = (d["where"] as? [String: Any]) ?? d
        q.name = src["name"] as? String
        q.type = src["type"] as? String
        q.fill = src["fill"] as? String
        q.stroke = src["stroke"] as? String
        q.text = src["text"] as? String
        q.visible = src["visible"] as? Bool
        q.minWidth = src["minWidth"] as? Double
        q.maxWidth = src["maxWidth"] as? Double
        q.selectedOnly = src["selectedOnly"] as? Bool
        q.limit = src["limit"] as? Int
        return q
    }

    /// The tool description handed to a model. One place, so the prompt can't drift
    /// from what the executor actually accepts.
    public static var schema: String {
        """
        Reply with JSON only: {"commands":[ ... ]}. Each command is an object with
        "op" and a selector. The selector fields go inline (or nested under "where"):

          name         substring of the layer name, case-insensitive
          type         artboard | group | shapeGroup | path | text | image
          fill         hex, e.g. "#000000"
          stroke       hex
          text         substring of a text layer's content
          visible      true | false
          minWidth     number      maxWidth  number
          selectedOnly true — restrict to what the user has selected
          limit        number — cap how many layers are affected

        Operations:
          select
          delete
          setFill      hex
          setStroke    hex, width (optional)
          setOpacity   value (0-1 or 0-100)
          setVisible   value (true/false)   — or use op "show" / "hide"
          rename       pattern, where {i} is a 1-based index and {name} the old name
          move         dx, dy
          resize       width and/or height
          align        edge: left|centre|right|top|middle|bottom
          distribute   axis: horizontal|vertical
          order        where: front|back|forward|backward
          group        name (optional)
          ungroup

        Example — "make every black path 50% opacity":
        {"commands":[{"op":"setOpacity","type":"path","fill":"#000000","value":0.5}]}
        """
    }
}


// MARK: - Isolating a layer for export

extension Page {
    /// A one-layer page for exporting a single artboard or layer, plus the bounds to
    /// render at.
    ///
    /// Ancestor translation is folded into the layer's frame so a nested layer still
    /// exports in the right place. Rotation on an ancestor isn't representable in a
    /// frame — rare enough in practice, and reported rather than silently wrong.
    public func isolate(_ id: String) -> (page: Page, bounds: CGRect, rotatedAncestor: Bool)? {
        var found: (Layer, CGPoint, Bool)?
        func walk(_ ls: [Layer], _ offset: CGPoint, _ rotated: Bool) {
            for l in ls {
                let here = CGPoint(x: offset.x + l.frame.minX, y: offset.y + l.frame.minY)
                if l.id == id { found = (l, offset, rotated); return }
                let spun = rotated || l.rotation != 0 || l.flipH || l.flipV
                switch l.kind {
                case .group(let k), .shapeGroup(let k, _): walk(k, here, spun)
                default: continue
                }
                if found != nil { return }
            }
        }
        walk(layers, .zero, false)
        guard let (layer, offset, rotated) = found else { return nil }

        var moved = layer
        moved.frame.origin = CGPoint(x: layer.frame.minX + offset.x,
                                     y: layer.frame.minY + offset.y)
        var p = Page(name: layer.name)
        p.layers = [moved]
        return (p, moved.frame, rotated)
    }

    /// Every artboard on the page, outermost first.
    public var artboards: [Layer] {
        var out: [Layer] = []
        func walk(_ ls: [Layer]) {
            for l in ls {
                if l.isArtboard { out.append(l) }
                switch l.kind {
                case .group(let k), .shapeGroup(let k, _): walk(k)
                default: continue
                }
            }
        }
        walk(layers)
        return out
    }
}
