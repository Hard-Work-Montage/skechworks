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
    /// Anchor count, so a model can act on what describe() shows it. Without this it
    /// can see which layers are over-detailed and has no way to say so.
    public var minPoints: Int?
    public var maxPoints: Int?
    public var minWidth: Double?
    public var maxWidth: Double?
    /// Restrict to the current selection.
    public var selectedOnly: Bool?
    /// Cap the result, so a mistaken query can't rewrite a whole document.
    public var limit: Int?

    public init() {}

    /// No selector at all. Callers must treat this as "whatever is already scoped",
    /// never as "everything" — a model writes `{"op":"delete"}` meaning the thing it
    /// just selected.
    public var isEmpty: Bool {
        name == nil && type == nil && fill == nil && stroke == nil && text == nil
            && visible == nil && minWidth == nil && maxWidth == nil && selectedOnly == nil
            && minPoints == nil && maxPoints == nil
    }
}

extension Layer {
    /// Public so the MCP tools can report what a layer is without duplicating the map.
    public var apiType: String {
        switch kind {
        case .group: return isArtboard ? "artboard" : "group"
        case .shapeGroup: return "shapeGroup"
        case .path: return "path"
        case .text: return "text"
        case .bitmap: return "image"
        }
    }

    public var apiText: String? {
        if case .text(let t) = kind { return t.string }
        return nil
    }

    public var firstFillHex: String? {
        guard case .color(let c)? = style.fills.first?.paint else { return nil }
        return c.hex
    }

    public func matches(_ q: LayerQuery) -> Bool {
        if let n = q.name, !name.localizedCaseInsensitiveContains(n) { return false }
        if let t = q.type, apiType.lowercased() != t.lowercased() { return false }
        if let f = q.fill, firstFillHex?.lowercased() != f.lowercased() { return false }
        if let s = q.stroke, style.borders.first?.color.hex.lowercased() != s.lowercased() { return false }
        if let t = q.text {
            guard let content = apiText, content.localizedCaseInsensitiveContains(t) else { return false }
        }
        if let v = q.visible, isVisible != v { return false }
        if let n = q.minPoints, (pointCount ?? 0) < n { return false }
        if let n = q.maxPoints, (pointCount ?? 0) > n { return false }
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
                // Only worth mentioning when it's enough to matter.
                if let n = l.pointCount, n >= 24 { bits.append("\(n) points") }
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
    /// Bend text round a circle. nil radius straightens it again.
    case curve(LayerQuery, radius: Double?, angle: Double?, flipped: Bool?)
    /// Create a layer. Takes no selector — there's nothing to select yet.
    case add(AddSpec)
    case duplicate(LayerQuery, dx: Double, dy: Double, times: Int)
    /// Refit paths with fewer points. Tolerance is in page units.
    case simplify(LayerQuery, tolerance: Double?, detail: Double?)

    public var query: LayerQuery {
        switch self {
        case .select(let q), .delete(let q), .ungroup(let q): return q
        case .setFill(let q, _), .setOpacity(let q, _), .setVisible(let q, _): return q
        case .setStroke(let q, _, _), .rename(let q, _), .align(let q, _): return q
        case .move(let q, _, _), .resize(let q, _, _): return q
        case .distribute(let q, _), .order(let q, _), .group(let q, _): return q
        case .curve(let q, _, _, _): return q
        case .duplicate(let q, _, _, _): return q
        case .simplify(let q, _, _): return q
        case .add: return LayerQuery()
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
        case .curve(_, let r, _, _): return r == nil ? "Straighten Text" : "Curve Text"
        case .add(let spec): return "Add \(spec.kind.capitalized)"
        case .simplify: return "Simplify"
        case .duplicate(_, _, _, let n): return n > 1 ? "Duplicate ×\(n)" : "Duplicate"
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
        /// Models pick reasonable-but-different parameter names — a real reply used
        /// "value" for a colour where the schema said "hex". Rejecting that dropped
        /// the whole command and left the model's claim standing with nothing behind
        /// it. Accept the obvious synonyms instead of spending a round trip.
        func s(_ keys: String...) -> String? {
            for k in keys { if let v = d[k] as? String { return v } }
            return nil
        }
        func n(_ keys: String...) -> Double? {
            for k in keys {
                if let v = d[k] as? Double { return v }
                if let v = d[k] as? Int { return Double(v) }
            }
            return nil
        }
        func b(_ keys: String...) -> Bool? {
            for k in keys { if let v = d[k] as? Bool { return v } }
            return nil
        }

        switch op.lowercased() {
        case "select": return .select(q)
        case "delete": return .delete(q)
        case "setfill", "fill":
            return s("hex", "value", "color", "colour", "to").map { .setFill(q, hex: $0) }
        case "setstroke", "stroke":
            return s("hex", "value", "color", "colour", "to").map { .setStroke(q, hex: $0, width: n("width")) }
        case "setopacity", "opacity":
            guard let v = n("value") else { return nil }
            return .setOpacity(q, value: v > 1 ? v / 100 : v)   // accept 50 or 0.5
        case "setvisible", "show", "hide":
            let v = (d["value"] as? Bool) ?? (op.lowercased() == "show")
            return .setVisible(q, value: v)
        case "rename": return s("pattern", "value", "to", "name").map { .rename(q, pattern: $0) }
        case "move": return .move(q, dx: n("dx") ?? 0, dy: n("dy") ?? 0)
        case "resize": return .resize(q, width: n("width"), height: n("height"))
        case "align": return s("edge", "value", "to").map { .align(q, edge: $0) }
        case "distribute": return .distribute(q, axis: s("axis", "value") ?? "horizontal")
        case "order", "arrange", "bringtofront", "sendtoback":
            let fallback = op.lowercased() == "sendtoback" ? "back" : "front"
            return .order(q, where: s("where", "value", "to") ?? fallback)
        case "group": return .group(q, name: s("name", "value"))
        case "ungroup": return .ungroup(q)
        case "add", "create", "insert", "new":
            var spec = AddSpec()
            // The kind can arrive as the op's argument or baked into the op name.
            spec.kind = (s("kind", "type", "shape", "what", "value") ?? "rect").lowercased()
            spec.name = s("name", "label")
            spec.text = s("text", "string", "content")
            spec.font = s("font", "fontName")
            spec.fill = s("fill", "color", "colour", "background")
            spec.parent = s("parent", "in", "into", "artboard")
            spec.x = n("x", "left"); spec.y = n("y", "top")
            spec.width = n("width", "w"); spec.height = n("height", "h")
            spec.fontSize = n("fontSize", "size")
            return .add(spec)
        case "addartboard", "newartboard", "createartboard":
            var spec = AddSpec()
            spec.kind = "artboard"
            spec.name = s("name", "label", "value")
            spec.x = n("x"); spec.y = n("y")
            spec.width = n("width", "w"); spec.height = n("height", "h")
            spec.fill = s("fill", "color", "colour", "background")
            return .add(spec)
        case "simplify", "reducepoints", "smooth":
            return .simplify(q, tolerance: n("tolerance", "value", "epsilon"),
                             detail: n("detail", "amount", "strength", "aggressiveness"))
        case "duplicate", "copy", "clone":
            return .duplicate(q, dx: n("dx", "offsetX") ?? 20, dy: n("dy", "offsetY") ?? 20,
                              times: Int(n("times", "count", "copies") ?? 1))
        case "curve", "arc", "curvetext":
            // "straighten" and an explicit null both mean "take the curve off".
            let straighten = d["straighten"] as? Bool == true
            return .curve(q,
                          radius: straighten ? nil : n("radius", "r"),
                          angle: n("angle", "rotation"),
                          flipped: b("flipped", "flip", "upright"))
        default: return nil
        }
    }

    public static func decodeList(_ data: Data) -> [DocumentCommand] {
        decodeReport(data).commands
    }

    /// Decoding, with the failures kept.
    ///
    /// Dropping an unreadable command silently is how a model's "done!" ends up
    /// attached to nothing happening. Whatever couldn't be read gets reported.
    public static func decodeReport(_ data: Data) -> (commands: [DocumentCommand], problems: [String]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return ([], ["The reply wasn't valid JSON."])
        }
        var raw: [Any] = []
        if let arr = root as? [Any] { raw = arr }
        else if let obj = root as? [String: Any] {
            if let arr = obj["commands"] as? [Any] { raw = arr }
            else if obj["op"] != nil { raw = [obj] }
        }
        var commands: [DocumentCommand] = []
        var problems: [String] = []
        for item in raw {
            if let c = decode(item) {
                commands.append(c)
            } else {
                let op = (item as? [String: Any])?["op"] as? String ?? "?"
                problems.append("Couldn't read a “\(op)” command — missing or unexpected parameters.")
            }
        }
        return (commands, problems)
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
        q.minPoints = (src["minPoints"] as? Int) ?? (src["minPoints"] as? Double).map(Int.init)
        q.maxPoints = (src["maxPoints"] as? Int) ?? (src["maxPoints"] as? Double).map(Int.init)
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
        Reply with JSON only: {"say": "...", "commands":[ ... ]}.

        "say" is what you tell the user — one or two sentences, plain language. Use it
        alone (with no commands, or an empty list) to ask a clarifying question or to
        explain why you can't do something.

        Each command is an object with "op" and a selector. The selector fields go
        inline (or nested under "where"):

          name         substring of the layer name, case-insensitive
          type         artboard | group | shapeGroup | path | text | image
          fill         hex, e.g. "#000000"
          stroke       hex
          text         substring of a text layer's content
          visible      true | false
          minWidth     number      maxWidth  number
          minPoints    number — anchor count, matching the "N points" shown above.
                       This is how you target over-detailed paths.
          maxPoints    number
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
          add          kind: artboard|rect|ellipse|text|line, plus any of
                       name, x, y, width, height, fill, text, font, fontSize,
                       and parent (the name of an artboard to put it inside).
                       Everything is optional — omit what you don't care about and
                       sensible defaults are used. This is how you CREATE layers;
                       every other operation only changes ones that already exist.
          duplicate    dx, dy, times
          simplify     tolerance (page units — how far the path may move) or
                       detail (0-1, where 1 keeps almost everything and 0.2 is
                       aggressive). Refits paths with fewer points. Layers report
                       their point count above, so target the heavy ones with
                       minPoints; a shape that is genuinely intricate is not the same
                       as one that was traced badly.

        Example — "clean up the traced shapes":
        {"say":"Simplified the paths carrying far more points than they need.",
         "commands":[{"op":"simplify","type":"path","minPoints":80,"detail":0.5}]}
          curve        radius, angle (degrees clockwise from 12 o'clock), flipped
                       Inside an artboard the ring is centred on the artboard, so
                       don't try to position the text first — set angle 180 for the
                       bottom, 0 for the top, 90 for the right.
                       — bends a text layer round a circle centred on its frame.
                       Use flipped:true for text along the bottom so it reads
                       upright. {"op":"curve","straighten":true} removes the curve.

        Example — "make every black path 50% opacity":
        {"say":"Dropped the black paths to 50%.",
         "commands":[{"op":"setOpacity","type":"path","fill":"#000000","value":0.5}]}

        Example — "make a new artboard":
        {"say":"Added a 500×500 artboard.",
         "commands":[{"op":"add","kind":"artboard","name":"Artboard"}]}

        Example — the request is ambiguous:
        {"say":"Do you mean the artboards themselves, or the shapes inside them?",
         "commands":[]}

        Commands run in order. A command with no selector acts on whatever the
        previous select matched, or on the layer the previous "add" created. After
        adding something, leave the selector OFF the commands that follow — naming it
        again risks matching other layers that happen to share the name or type, and
        changing those too.

        Example — "add curved text along the bottom of a new artboard":
        {"say":"Added the artboard and curved the text along its bottom.",
         "commands":[{"op":"add","kind":"artboard","name":"Back"},
                     {"op":"add","kind":"text","text":"8760 HOURS","parent":"Back"},
                     {"op":"curve","radius":200,"angle":180,"flipped":true}]}

        Prefer one precise command over a select+act pair.
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


// MARK: - Change detection

extension Layer {
    /// A cheap signature of everything an edit can change.
    ///
    /// Used to tell a real edit from a no-op. Comparing only ids and frames — which is
    /// what this replaced — silently discarded every rename, recolour and opacity
    /// change, because none of those move anything.
    public var contentSignature: String {
        var s = "\(id)|\(name)|\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
        s += "|\(isVisible ? 1 : 0)|\(Int(style.opacity * 1000))|\(Int(rotation))"
        s += "|\(firstFillHex ?? "-")|\(style.borders.first.map { "\($0.color.hex):\(Int($0.thickness)) " } ?? "-")"
        s += "|\(isArtboard ? 1 : 0)\(backgroundInExport ? 1 : 0)\(backgroundColor?.hex ?? "-")"
        // Marking a mask changes no geometry. Left out, mutatePage sees an unchanged
        // page and throws the edit away — which it did whenever the shape was already
        // at the back, so Use as Mask worked from the layer list and not from the canvas.
        s += "|\(hasClippingMask ? 1 : 0)\(breaksMaskChain ? 1 : 0)"
        if let t = apiText { s += "|\(t)" }
        if case .path(let p, let closed) = kind {
            // Points move without the frame changing, so include the geometry's own
            // extent — cheaper than hashing every curve.
            let b = p.boundingBoxOfPath
            s += "|\(Int(b.minX)),\(Int(b.minY)),\(Int(b.width)),\(Int(b.height)),\(closed ? 1 : 0)"
            // Switching Mirrored to Aligned changes no geometry at all. Left out of
            // the signature, mutatePage sees no change and throws the edit away.
            if !curveModes.isEmpty { s += "|" + curveModes.map { String($0.rawValue) }.joined() }
        }
        switch kind {
        case .group(let k), .shapeGroup(let k, _):
            s += "[" + k.map(\.contentSignature).joined(separator: ";") + "]"
        default: break
        }
        return s
    }
}

extension Page {
    public var contentSignature: String {
        layers.map(\.contentSignature).joined(separator: ";")
    }
}

// MARK: - A model's reply

/// What comes back from a turn: something to say, and optionally something to do.
/// The instructions a model gets, in one place.
///
/// This lived in the app's connector, which meant the CLI harness that catches
/// prompt-level bugs was testing a copy rather than the real thing — and a copy
/// drifts. Both callers share it now.
public enum ModelPrompt {
    public static var system: String {
        """
        You edit a vector design document, working alongside the user. Be brief.

        \(DocumentCommand.schema)

        Act rather than asking permission — the user can undo anything in one step. \
        Ask only when a request is genuinely ambiguous and guessing would waste their \
        time. If something can't be done with these operations, say so plainly in \
        "say" and return no commands.
        """
    }

    public static func user(document: String, request: String) -> String {
        "CURRENT DOCUMENT\n\(document)\n\nREQUEST\n\(request)"
    }
}

public struct ModelTurn: Sendable {
    public var say: String
    public var commands: [DocumentCommand]

    public init(say: String, commands: [DocumentCommand]) {
        self.say = say
        self.commands = commands
    }

    public var problems: [String] = []

    public static func decode(_ data: Data) -> ModelTurn {
        let report = DocumentCommand.decodeReport(data)
        let commands = report.commands
        var say = ""
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            say = (obj["say"] as? String) ?? (obj["message"] as? String) ?? ""
        }
        var turn = ModelTurn(say: say, commands: commands)
        turn.problems = report.problems
        return turn
    }

    /// Whether this turn is worth stopping for.
    ///
    /// Ordinary edits just happen — undo is right there, and asking permission for
    /// every recolour makes a tool feel like it doesn't trust you. What still deserves
    /// a pause is the combination that undo alone doesn't make comfortable: destroying
    /// things, or touching far more than you'd expect from one sentence.
    public func needsConfirmation(affecting count: Int) -> Bool {
        let destructive = commands.contains {
            if case .delete = $0 { return true }
            if case .ungroup = $0 { return true }
            return false
        }
        if destructive && count > 3 { return true }
        return count > 40
    }
}
