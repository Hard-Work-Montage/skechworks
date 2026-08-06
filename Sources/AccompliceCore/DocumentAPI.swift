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
    /// Containers with nothing inside — the cleanup case.
    public var empty: Bool?
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
            && minPoints == nil && maxPoints == nil && empty == nil
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
        if let e = q.empty {
            let childCount: Int?
            switch kind {
            case .group(let k), .shapeGroup(let k, _): childCount = k.count
            default: childCount = nil
            }
            if e { guard childCount == 0 else { return false } }
            else if childCount == 0 { return false }
        }
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

    /// What a rubber-band selects: every visible, unlocked layer whose painted
    /// bounds touch the rect. Artboards are never themselves hits — the label is
    /// the handle for a board — but the art sitting on one is, which is what makes
    /// a marquee started inside an artboard behave like one started outside.
    /// Groups stay atomic: the group is the hit, not its members.
    public func marqueeHits(_ rect: CGRect) -> Set<String> {
        var hits: Set<String> = []
        func walk(_ ls: [Layer], _ base: CGAffineTransform, _ clip: CGRect?) {
            for l in ls where l.isVisible && !l.isLocked {
                let t = Compose.transform(l).concatenating(base)
                if l.isArtboard {
                    // The board clips its children — for hits exactly as for paint,
                    // so a marquee in one panel can't catch the invisible tail of a
                    // neighbouring panel's art.
                    let boardRect = CGRect(origin: .zero, size: l.frame.size).applying(t)
                    let inner = clip.map { $0.intersection(boardRect) } ?? boardRect
                    if case .group(let kids) = l.kind { walk(kids, t, inner) }
                    continue
                }
                var box = (Compose.resolvedPath(l)?.transformed(by: t).boundingBoxOfPath)
                    ?? CGRect(origin: .zero, size: l.frame.size).applying(t)
                if let clip { box = box.intersection(clip) }
                if !box.isNull, rect.intersects(box) { hits.insert(l.id) }
            }
        }
        walk(layers, .identity, nil)
        return hits
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
                if l.isLocked { bits.append("locked") }
                switch l.kind {
                case .group(let k) where k.isEmpty, .shapeGroup(let k, _) where k.isEmpty:
                    bits.append("empty")
                default: break
                }
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

        // The tree above truncates, but colour questions ("delete everything with
        // this fill") need the WHOLE page's palette — a model that can't see a
        // colour concludes it doesn't exist and refuses to touch it. A vectorized
        // trace put the colour a user asked about at layer 700 of 900.
        var fills: [String: Int] = [:]
        func tally(_ ls: [Layer]) {
            for l in ls {
                if let f = l.firstFillHex { fills[f.lowercased(), default: 0] += 1 }
                switch l.kind {
                case .group(let k), .shapeGroup(let k, _): tally(k)
                default: break
                }
            }
        }
        tally(layers)
        if !fills.isEmpty {
            let sorted = fills.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let shown = sorted.prefix(40).map { "\($0.key) ×\($0.value)" }.joined(separator: "  ")
            let more = sorted.count > 40 ? "  … \(sorted.count - 40) more" : ""
            lines.append("fills used (every layer, including any truncated above): \(shown)\(more)")
        }
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
    case setLocked(LayerQuery, value: Bool)
    case rename(LayerQuery, pattern: String)
    /// Change a text layer's words, face or size — whichever are given.
    case setText(LayerQuery, text: String?, font: String?, size: Double?)
    case move(LayerQuery, dx: Double, dy: Double)
    case resize(LayerQuery, width: Double?, height: Double?)
    case align(LayerQuery, edge: String)
    /// Mirror in place: axis "horizontal" | "vertical".
    case flip(LayerQuery, axis: String)
    case distribute(LayerQuery, axis: String)
    case order(LayerQuery, where: String)   // front | back | forward | backward
    /// Reorder the layer list itself: position (canvas reading order) | name.
    case sort(LayerQuery, by: String)
    case group(LayerQuery, name: String?)
    case ungroup(LayerQuery)
    /// Bend text round a circle. nil radius straightens it again.
    case curve(LayerQuery, radius: Double?, angle: Double?, flipped: Bool?)
    case distort(LayerQuery, corners: [Double]?)
    /// Create a layer. Takes no selector — there's nothing to select yet.
    case add(AddSpec)
    /// Combine into one shape: union | subtract | intersect | difference | flatten.
    case combine(LayerQuery, op: String)
    case duplicate(LayerQuery, dx: Double, dy: Double, times: Int)
    /// Refit paths with fewer points. Tolerance is in page units.
    case simplify(LayerQuery, tolerance: Double?, detail: Double?)

    public var query: LayerQuery {
        switch self {
        case .select(let q), .delete(let q), .ungroup(let q): return q
        case .setFill(let q, _), .setOpacity(let q, _), .setVisible(let q, _): return q
        case .setLocked(let q, _): return q
        case .setStroke(let q, _, _), .rename(let q, _), .align(let q, _): return q
        case .setText(let q, _, _, _): return q
        case .move(let q, _, _), .resize(let q, _, _): return q
        case .distribute(let q, _), .order(let q, _), .group(let q, _): return q
        case .flip(let q, _): return q
        case .sort(let q, _): return q
        case .curve(let q, _, _, _): return q
        case .distort(let q, _): return q
        case .duplicate(let q, _, _, _): return q
        case .simplify(let q, _, _): return q
        case .add: return LayerQuery()
        case .combine(let q, _): return q
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
        case .setLocked(_, let v): return v ? "Lock" : "Unlock"
        case .rename: return "Rename"
        case .flip(_, let a): return a.lowercased().hasPrefix("v") ? "Flip Vertical" : "Flip Horizontal"
        case .setText: return "Edit Text"
        case .move: return "Move"
        case .resize: return "Resize"
        case .curve(_, let r, _, _): return r == nil ? "Straighten Text" : "Curve Text"
        case .distort(_, let c): return c == nil ? "Flatten Distort" : "Distort"
        case .add(let spec): return "Add \(spec.kind.capitalized)"
        case .combine(_, let op): return op.capitalized
        case .simplify: return "Simplify"
        case .duplicate(_, _, _, let n): return n > 1 ? "Duplicate ×\(n)" : "Duplicate"
        case .align(_, let e): return "Align \(e)"
        case .distribute(_, let a): return "Distribute \(a)"
        case .order(_, let w): return "Order \(w)"
        case .sort(_, let by): return "Sort by \(by)"
        case .group: return "Group"
        case .ungroup: return "Ungroup"
        }
    }
}

// MARK: - JSON

/// The first number in a string, ignoring whatever it's wrapped in.
///
/// Deliberately forgiving in one direction only: it reads a number out of decoration,
/// it never invents one. "half" stays nil, so the command is refused and reported
/// rather than quietly becoming 0.
func number(in s: String) -> Double? {
    var digits = ""
    var seenDot = false
    for ch in s {
        if ch.isNumber { digits.append(ch) }
        else if ch == "." && !seenDot && !digits.isEmpty { seenDot = true; digits.append(ch) }
        else if ch == "-" && digits.isEmpty { digits.append(ch) }
        else if !digits.isEmpty && digits != "-" { break }
    }
    guard digits.hasSuffix(".") ? digits.count > 1 : !digits.isEmpty, digits != "-" else { return nil }
    return Double(digits.hasSuffix(".") ? String(digits.dropLast()) : digits)
}

extension DocumentCommand {

    /// Decodes `{"op": "...", ...}`. Written by hand rather than derived so the wire
    /// format stays flat and obvious — a model writes this, and every nested
    /// discriminator is another thing for it to get subtly wrong.
    public static func decode(_ any: Any) -> DocumentCommand? {
        guard let d = any as? [String: Any], let op = d["op"] as? String else { return nil }
        let q = decodeQuery(d)
        /// Models pick reasonable-but-different parameter names — a real reply used
        /// "value" for a color where the schema said "hex". Rejecting that dropped
        /// the whole command and left the model's claim standing with nothing behind
        /// it. Accept the obvious synonyms instead of spending a round trip.
        func s(_ keys: String...) -> String? {
            for k in keys { if let v = d[k] as? String { return v } }
            return nil
        }
        /// A colour, wherever the model put it. Real replies wrap it in an object
        /// ({"color": {"hex": "#fff"}}) as often as they write the string.
        func colour(_ keys: String...) -> String? {
            for k in keys {
                if let v = d[k] as? String { return v }
                if let o = d[k] as? [String: Any] {
                    for kk in [ "hex", "value", "color", "colour" ] {
                        if let v = o[kk] as? String { return v }
                    }
                }
            }
            return nil
        }
        func n(_ keys: String...) -> Double? {
            for k in keys {
                if let v = d[k] as? Double { return v }
                if let v = d[k] as? Int { return Double(v) }
                // Numbers arrive as strings, and dressed up. Asked for 50% opacity,
                // real models returned "50", "50%", "0.5" and "{0.5}" — the same
                // request, four models, four spellings. Refusing them dropped the
                // command while the model's "done" stood with nothing behind it,
                // which is the one outcome worse than an error.
                if let v = d[k] as? String, let parsed = number(in: v) { return parsed }
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
            if let hex = colour("hex", "value", "color", "colour", "to") {
                return .setFill(q, hex: hex)
            }
            // "Set the fill to X" naturally arrives as {"op":"setFill","fill":"#..."}
            // — but "fill" is a selector key, so the colour landed in the query and
            // the command decoded as "recolor to nothing" and was dropped. With no
            // other colour present, "fill" IS the colour, not a filter.
            if let hex = colour("fill") {
                var q2 = q; q2.fill = nil
                return .setFill(q2, hex: hex)
            }
            return nil
        case "setstroke", "stroke":
            if let hex = colour("hex", "value", "color", "colour", "to") {
                return .setStroke(q, hex: hex, width: n("width"))
            }
            if let hex = colour("stroke") {
                var q2 = q; q2.stroke = nil
                return .setStroke(q2, hex: hex, width: n("width"))
            }
            return nil
        case "setopacity", "opacity":
            guard let v = n("value") else { return nil }
            return .setOpacity(q, value: v > 1 ? v / 100 : v)   // accept 50 or 0.5
        case "setvisible", "show", "hide":
            let v = (d["value"] as? Bool) ?? (op.lowercased() == "show")
            return .setVisible(q, value: v)
        case "lock", "unlock", "setlocked":
            let v = (d["value"] as? Bool) ?? (op.lowercased() != "unlock")
            return .setLocked(q, value: v)
        case "rename": return s("pattern", "value", "to", "name").map { .rename(q, pattern: $0) }
        case "settext", "setstring", "changetext", "edittext":
            let text = s("text", "string", "value", "to", "content")
            let font = s("font", "fontName", "face")
            let size = n("size", "fontSize")
            guard text != nil || font != nil || size != nil else { return nil }
            // "text" here is the NEW content, not a content filter — the query
            // decoder grabbed it as one too, which made every setText match
            // nothing. Use "contains" to filter by current content instead.
            var tq = q
            tq.text = s("contains", "matching")
            return .setText(tq, text: text, font: font, size: size)
        case "move": return .move(q, dx: n("dx") ?? 0, dy: n("dy") ?? 0)
        case "resize": return .resize(q, width: n("width"), height: n("height"))
        case "align": return s("edge", "value", "to").map { .align(q, edge: $0) }
        case "flip", "mirror", "fliphorizontal", "flipvertical":
            var axis = s("axis", "value", "direction") ?? ""
            if axis.isEmpty { axis = op.lowercased().contains("vertical") ? "vertical" : "horizontal" }
            return .flip(q, axis: axis)
        case "distribute": return .distribute(q, axis: s("axis", "value") ?? "horizontal")
        case "order", "arrange", "bringtofront", "sendtoback":
            // "arrange by position" is a sort, not a restack — the "by" gives it away.
            if let by = s("by", "sortBy") { return .sort(q, by: by.lowercased()) }
            let fallback = op.lowercased() == "sendtoback" ? "back" : "front"
            return .order(q, where: s("where", "value", "to") ?? fallback)
        case "sort", "organize", "organise", "tidy", "reorder":
            return .sort(q, by: (s("by", "value", "key") ?? "position").lowercased())
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
            spec.sides = n("sides", "points").map(Int.init)
            spec.innerRatio = n("innerRatio", "inner")
            spec.d = s("d", "path", "pathData", "data")
            spec.stroke = s("stroke", "strokeColor", "strokeColour", "border")
            spec.strokeWidth = n("strokeWidth", "thickness", "weight", "borderWidth")
            spec.strokeCap = s("strokeCap", "cap", "linecap", "strokeLinecap")
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
        case "combine", "union", "subtract", "intersect", "difference", "flatten":
            // The operation can be the op name itself or an argument.
            let named = op.lowercased()
            let which = named == "combine"
                ? (s("op", "operation", "value", "with") ?? "union")
                : named
            return .combine(q, op: which)
        case "curve", "arc", "curvetext":
            // "straighten" and an explicit null both mean "take the curve off".
            let straighten = d["straighten"] as? Bool == true
            return .curve(q,
                          radius: straighten ? nil : n("radius", "r"),
                          angle: n("angle", "rotation"),
                          flipped: b("flipped", "flip", "upright"))
        case "distort", "skew", "perspective", "warp":
            if d["straighten"] as? Bool == true || d["reset"] as? Bool == true {
                return .distort(q, corners: nil)
            }
            let nums = (d["corners"] as? [Any])?.compactMap { v -> Double? in
                if let x = v as? Double { return x }
                if let i = v as? Int { return Double(i) }
                return nil
            }
            guard let nums, nums.count == 8 else { return nil }
            return .distort(q, corners: nums)
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
    /// The JSON out of a reply that may be wrapped in something.
    ///
    /// Models fence their replies in ```json even when the request asked for JSON
    /// and nothing else, and they sometimes say a sentence before it. Parsing the
    /// raw bytes threw the whole turn away for punctuation: a real trace came back
    /// with six correctly stroked paths inside a fence, decoded to zero commands,
    /// and the draw loop stopped there believing the model had nothing to add.
    /// Rejecting good work over a wrapper is the worst trade available here.
    public static func unwrap(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if s.hasPrefix("```") {
            // Drop the opening fence and its language tag, then the closing one.
            if let firstBreak = s.firstIndex(where: \.isNewline) {
                s = String(s[s.index(after: firstBreak)...])
            }
            if let close = s.range(of: "```", options: .backwards) {
                s = String(s[..<close.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Still not JSON? Take what sits between the outermost braces or brackets,
        // which is what a model that chats before answering leaves behind.
        if !s.hasPrefix("{"), !s.hasPrefix("[") {
            let opens = [s.firstIndex(of: "{"), s.firstIndex(of: "[")].compactMap { $0 }
            let closes = [s.lastIndex(of: "}"), s.lastIndex(of: "]")].compactMap { $0 }
            if let start = opens.min(), let end = closes.max(), start < end {
                s = String(s[start...end])
            }
        }
        return Data(s.utf8)
    }

    public static func decodeReport(_ data: Data) -> (commands: [DocumentCommand], problems: [String]) {
        guard let root = try? JSONSerialization.jsonObject(with: unwrap(data)) else {
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
          empty        true — containers with nothing inside (cleanup after ungrouping)
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
          setText      text, font, size — changes a TEXT layer's content, face or
                       size; give whichever you mean to change. This edits the
                       words on the canvas; "rename" only changes the layer's
                       NAME in the list.
          move         dx, dy
          resize       width and/or height
          align        edge: left|center|right|top|middle|bottom
          flip         axis: horizontal|vertical — mirrors in place
          distribute   axis: horizontal|vertical
          order        where: front|back|forward|backward
          sort         by: position|name — reorders the LAYER LIST. "position"
                       puts it in canvas reading order (top-left first), "name"
                       alphabetises. With no selector it sorts the whole page's
                       top-level layers, which is usually what's wanted. This is
                       the whole job in ONE command — never spell it out as
                       selects and moves.
          group        name (optional)
          ungroup
          add          kind: artboard|rect|ellipse|text|line|star|polygon|path,
                       star/polygon take sides (star points) and innerRatio
                       (star spike depth, 0-1); path takes d, SVG path data in
                       THIS page's coordinates (y down, same as an SVG "d"
                       attribute) — use it for any curve that isn't one of the
                       shapes above, and give width/height only if you want the
                       data scaled to fit them; plus any of
                       stroke and strokeWidth (a path with a stroke and no fill
                       draws hollow, which is what outline drawings want), and
                       name, x, y, width, height, fill, text, font, fontSize,
                       and parent (the name of an artboard to put it inside).
                       Everything is optional — omit what you don't care about and
                       sensible defaults are used. This is how you CREATE layers;
                       every other operation only changes ones that already exist.
          duplicate    dx, dy, times
          combine      op: union|subtract|intersect|difference|flatten — makes one
                       shape from the matched layers. The BOTTOM layer is the base and
                       the ones above it are applied to it, so subtract depends on
                       layer order. Or use the operation as the op name directly.
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
          distort      corners — perspective-warps a BITMAP layer. Eight numbers
                       in unit coordinates of the frame, corner order top-left,
                       top-right, bottom-right, bottom-left, each as x,y:
                       flat is [0,0, 1,0, 1,1, 0,1]. Pull the right edge inward
                       and upward, e.g. [0,0, 0.85,0.1, 0.85,0.9, 0,1], and the
                       bitmap leans away like a wall in perspective. Corners may
                       go outside 0…1. {"op":"distort","straighten":true}
                       flattens it again. Aliases: skew, perspective, warp.

        Example — "make every black path 50% opacity":
        {"say":"Dropped the black paths to 50%.",
         "commands":[{"op":"setOpacity","type":"path","fill":"#000000","value":0.5}]}

        Example — "make a new artboard":
        {"say":"Added a 500×500 artboard.",
         "commands":[{"op":"add","kind":"artboard","name":"Artboard"}]}

        Example — "organize the layers in the layer list by their location
        in the canvas":
        {"say":"Reordered the layer list to match the canvas, top-left first.",
         "commands":[{"op":"sort","by":"position"}]}

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
    /// Int that can't take the app down.
    ///
    /// `Int(someDouble)` traps on NaN and on anything past Int's range, and this
    /// getter runs on every single edit — so one bad number anywhere in a
    /// document turned the next drag into a crash, with the work unsaved. A
    /// change detector is a diagnostic; it has no business being the thing that
    /// loses somebody's drawing. Non-finite values compare equal to each other
    /// here, which is right: the signature only has to answer "did this change".
    private func whole(_ v: CGFloat) -> Int {
        guard v.isFinite else { return v.isNaN ? Int.min : (v > 0 ? Int.max : Int.min + 1) }
        return Int(min(max(v, -1e15), 1e15))
    }

    public var contentSignature: String {
        var s = "\(id)|\(name)|\(whole(frame.minX)),\(whole(frame.minY)),\(whole(frame.width)),\(whole(frame.height))"
        s += "|\(isVisible ? 1 : 0)|\(whole(style.opacity * 1000))|\(whole(rotation * 100))"
        // EVERY fill and border, not just the first, and including alpha — `hex` is
        // #rrggbb only. Seventh time this has caught an edit, and this one was found
        // by reading rather than by an edit vanishing: a colour well can change the
        // second fill, a fill's alpha, or one gradient stop, and the old signature
        // could see none of the three. Whatever replaces this must be exhaustive
        // by construction; a list you have to remember to extend will keep doing this.
        s += "|" + style.fills.map { f in
            let paint: String
            switch f.paint {
            case .color(let c): paint = "\(c.hex)\(whole(c.a * 1000))"
            case .gradient(let g):
                paint = "g\(g.kind.rawValue):\(whole(g.from.x * 100)),\(whole(g.from.y * 100))"
                    + ":\(whole(g.to.x * 100)),\(whole(g.to.y * 100)):"
                    + g.stops.map { "\(whole($0.position * 1000))@\($0.color.hex)\(whole($0.color.a * 1000))" }
                        .joined(separator: "/")
            }
            return "\(paint)x\(whole(f.opacity * 1000))"
        }.joined(separator: ",")
        s += "|" + style.borders.map {
            "\($0.color.hex)\(whole($0.color.a * 1000)):\(whole($0.thickness * 100)):\($0.position.rawValue)"
                + ":\($0.dashPattern.map { d in String(whole(d)) }.joined(separator: "-"))"
        }.joined(separator: ",")
        s += "|\(isArtboard ? 1 : 0)\(backgroundInExport ? 1 : 0)"
        s += backgroundColor.map { "\($0.hex)\(whole($0.a * 1000))" } ?? "-"
        // Marking a mask changes no geometry. Left out, mutatePage sees an unchanged
        // page and throws the edit away — which it did whenever the shape was already
        // at the back, so Use as Mask worked from the layer list and not from the canvas.
        s += "|\(hasClippingMask ? 1 : 0)\(breaksMaskChain ? 1 : 0)\(constrainProportions ? 1 : 0)"
        // Adding a shadow moves nothing. Fourth thing to need saying here, so: if it
        // can be edited and isn't geometry, it belongs in the signature.
        // An erase moves nothing and changes no frame; without this the change detector
        // throws the stroke away. Sixth time, and the rule holds: if it can be edited
        // and isn't geometry, it belongs here.
        if !erased.isEmpty {
            s += "|e" + erased.map { "\($0.points.count):\(whole($0.radius)):\(whole($0.softness * 100))" }
                .joined(separator: ",")
        }
        s += "|" + style.shadows.map {
            "\($0.color.hex)\(whole($0.color.a * 100)):\(whole($0.offset.width)),\(whole($0.offset.height)):\(whole($0.blur)):\(whole($0.spread))"
        }.joined(separator: ",")
        if let t = apiText { s += "|\(t)" }
        if case .path(let p, let closed) = kind {
            // Points move without the frame changing, so include the geometry's own
            // extent — cheaper than hashing every curve.
            let b = p.boundingBoxOfPath
            s += "|\(whole(b.minX)),\(whole(b.minY)),\(whole(b.width)),\(whole(b.height)),\(closed ? 1 : 0)"
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

    /// Tracing a picture into shapes.
    ///
    /// Two instructions carry most of the weight. Draw what a shape IS rather than
    /// the outline a tracer would find, because a real ellipse is editable and a
    /// 300-point blob is not. And stop early: the failure here is a model grinding
    /// out shapes for antialiasing until the result is worse than the bitmap.
    public static func trace(width: CGFloat, height: CGFloat, lineArt: Bool = false) -> String {
        // Whether this is an outline drawing is measured, so it is stated
        // rather than left as a question. Asked to decide for itself, the model
        // took the other road on a plain rock-horns icon: one black silhouette
        // of the whole hand, then white shapes painted on top to carve the
        // holes back out. That needs seven shapes to agree with each other
        // exactly and it produced a black blob. Stroking six paths cannot fail
        // that way.
        let approach = lineArt ? """

        THIS IS AN OUTLINE DRAWING. That is measured, not a guess, so do not
        talk yourself out of it. Draw it as STROKED paths: every path gets a
        stroke and a strokeWidth and NO fill, and it runs down the MIDDLE of the
        ink rather than around the edge of it. One stroked path beats two
        outlines of the same finger.

        Never fill a silhouette and then paint background-coloured shapes on top
        to make the holes. It is the one approach here that cannot degrade
        gently: every white patch has to line up with the black underneath it,
        and where any of them falls short you get a solid blob instead of a
        drawing that is merely a bit off.

        Draw the INK, not the object. The black marks here are a hollow outline
        with white inside it; a filled shape of the same outline is a different
        picture. Where you would have filled a finger, stroke its outline
        instead and leave the middle empty.

        This is the shape of it — no "fill" key at all, which is what leaves it
        hollow. A "fill" alongside a stroke floods the middle:

        {"op":"add","kind":"path","name":"Index finger",
         "d":"M120 300 L120 140","stroke":"#000000","strokeWidth":19,
         "strokeCap":"round"}
        """ : """

        If the picture is an outline drawing — strokes of roughly one thickness,
        not filled regions — draw the strokes. Give each path a stroke and
        strokeWidth and NO fill, and run the path down the MIDDLE of the ink
        rather than around its edge. One stroked path beats two outlines of the
        same finger.
        """
        return trace(width: width, height: height, approach: approach)
    }

    private static func trace(width: CGFloat, height: CGFloat, approach: String) -> String {
        """
        You are redrawing a picture as vector shapes.

        \(DocumentCommand.schema)

        THE AREA
        \(Int(width)) wide, \(Int(height)) tall. 0,0 is the TOP LEFT and y increases
        DOWNWARD, exactly like an SVG. Every coordinate you give is in this space.

        PLAN IT FIRST
        Add a "plan" to your reply and write it BEFORE "commands" — first key in the
        object. The order is the point: the plan is for deciding what you are about
        to draw, and a plan written after the shapes is a description of them.

        Name the parts you can see and say, for each one, what you will draw it with
        and roughly where it sits. Count them. Then draw exactly those, and give each
        layer the name you used, so the next pass can talk about them.

        Say in one line how you are drawing it overall — stroked paths, or filled
        regions — and why. Commit there rather than deciding shape by shape, or the
        drawing ends up half one and half the other, which reads as neither.

        HOW TO DRAW IT
        Draw what each thing IS, not the outline a tracer would find around it. A
        round thing is an ellipse. A box is a rect, with cornerRadius if the corners
        are soft. Only reach for kind "path" with d when the shape is genuinely
        arbitrary, and then use as few curve segments as the shape needs.
        \(approach)

        Set strokeCap "round" on those unless the ends are visibly square. It rounds
        the corners too. Butted-flat ends and mitred corners are what make a traced
        icon look broken where a real one looks drawn.

        Prefer FEWER, LONGER paths. A finger that curves from the palm to its tip is
        one path with a few curve segments, not three short ones parked end to end:
        every join between two paths is a place the drawing can show a seam.

        You are told where the marks are, as a grid. Use it. Reading positions off
        the picture by eye is the one part of this you are worst at, and the grid is
        measured.

        Use the palette you are given. Do not invent colours, and do not trace the
        soft pixels along an edge; they are antialiasing, not artwork.

        Name every layer for what it is, so the result can be worked on afterwards.

        Fewest shapes that read as the picture. If you cannot do a part of it justice
        with these operations, leave it out and say so rather than approximating it
        with a hundred boxes.
        """
    }

    /// What to tell the model after it has seen its own attempt.
    /// What to say when an outline drawing came back as solid shapes.
    ///
    /// Worth its own message rather than a line in the report: it is not an
    /// error of degree like a stroke in the wrong place, so no amount of moving
    /// things fixes it, and the overlay shows it as a huge red mass that looks
    /// like every shape being wrong at once.
    public static let filledLineArt = """

    YOU FILLED THEM. Every shape you drew is solid, and the picture is hollow
    outlines — that is the whole red mass in the middle of the overlay, and it
    will not go away by moving anything.

    The shapes themselves are close. Keep them and change how they are drawn:
    give each one a stroke and a strokeWidth and take the fill OFF, so the
    middle goes back to white. Where a filled finger was right, the same outline
    stroked and hollow is right.
    """

    public static func traceAgain(report: String, pass: Int, plan: String = "",
                                  filledLineArt flooded: Bool = false) -> String {
        // The plan goes back with the picture. Without it the model re-derives
        // what it meant to draw from a rendering of what it managed to draw,
        // and a part it left out entirely has nothing left to remind it.
        let intent = plan.isEmpty ? "" : """

        WHAT YOU SAID YOU WERE DRAWING
        \(plan)

        Fix these by name. If a part on that list isn't in the picture, you never
        drew it — add it now rather than adjusting what is there.
        """
        return """
        ATTEMPT \(pass)\(flooded ? filledLineArt : "")\(intent)
        Three images: the original, what you drew, and the two laid on top of each
        other.

        READ THE THIRD ONE. In it, GREY is ink in the original that you have not
        drawn, RED is ink you drew where the original has none, and BLACK is where
        the two agree. So a red tip above a grey stub means that stroke runs too
        far; red beside grey means it sits to one side; grey with no red near it
        means you have missed something out entirely.

        Read thickness there too, because it is the one error that looks like
        every other one. Red down BOTH sides of a black line means your stroke is
        too thick; a thin black line with grey down both sides of it means yours
        is too thin. Fix strokeWidth before you move anything — a line of the
        wrong weight scores badly from exactly the right place, and chasing that
        with position is how a drawing gets worse.

        \(report)

        Fix the worst of it. Change what is wrong rather than starting over: move,
        resize, setFill or delete the layers you already made, by name. Add shapes
        only for parts of the picture that have nothing there yet. If it is as close
        as these operations reasonably get, return no commands and say so.
        """
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

    /// The parts list a trace writes before it draws anything.
    ///
    /// Only tracing asks for it, and only tracing reads it back. Empty
    /// everywhere else, and empty from any model that ignores the request.
    public var plan: String = ""

    public static func decode(_ data: Data) -> ModelTurn {
        let report = DocumentCommand.decodeReport(data)
        let commands = report.commands
        var say = ""
        var plan = ""
        // Same unwrapping as the commands, or a fenced reply would land its shapes
        // and lose the sentence and the plan that came with them.
        if let obj = try? JSONSerialization.jsonObject(with: DocumentCommand.unwrap(data)) as? [String: Any] {
            say = (obj["say"] as? String) ?? (obj["message"] as? String) ?? ""
            // Written as a list as often as a sentence, and both are worth having.
            if let text = obj["plan"] as? String {
                plan = text
            } else if let lines = obj["plan"] as? [Any] {
                plan = lines.map { String(describing: $0) }.joined(separator: "\n")
            }
        }
        var turn = ModelTurn(say: say, commands: commands)
        turn.problems = report.problems
        turn.plan = plan
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
