import CoreGraphics
import Foundation

/// What a batch of commands did.
public struct CommandRun: Sendable {
    /// One line per command, so what changed is never inferred.
    public var report = "Nothing matched."
    /// Set when the batch ended with a `select`.
    public var selection: Set<String>?
    public init(report: String = "Nothing matched.", selection: Set<String>? = nil) {
        self.report = report
        self.selection = selection
    }
}

extension Page {
    /// Runs a batch of commands against this page.
    ///
    /// This is the only thing that turns a model's output into document changes —
    /// the chat, the MCP server and the CLI all land here, so none of them can do
    /// something the others can't, and the scoping rule below is enforced once.
    public mutating func run(_ commands: [DocumentCommand],
                             selection: Set<String> = []) -> CommandRun {
        guard !commands.isEmpty else { return CommandRun(report: "Nothing to do.") }
        var report: [String] = []
        var pendingSelection: Set<String>?

        // A model naturally writes "select these, then delete" — two commands, the
        // second with no selector. An empty query matches EVERYTHING, so taken
        // literally that deletes the document. Carry the batch's last selection
        // forward instead, which is what was meant, and refuse an unscoped
        // destructive command outright.
        var scope: Set<String>? = selection.isEmpty ? nil : selection

        for c in commands {
            // Creation has nothing to select, so it can't go through the selector
            // path — an empty query there means "refused" or "everything".
            if case .add(let spec) = c {
                if let made = add(spec) {
                    pendingSelection = [made]
                    scope = [made]
                    report.append("\(c.summary): 1 layer")
                } else {
                    report.append("\(c.summary): couldn't create that")
                }
                continue
            }
            let ids: [String]
            if c.query.isEmpty {
                if case .sort = c, (scope?.count ?? 0) < 2 {
                    // "Organize the layers" with nothing named means the layer
                    // list itself — the page's rows. A single selected layer
                    // can't be "organized" either, so it doesn't count as a
                    // scope. Safe to default: sorting rearranges, never destroys.
                    ids = layers.map(\.id)
                } else {
                    guard let inherited = scope, !inherited.isEmpty else {
                        report.append("\(c.summary): refused — no layers specified")
                        continue
                    }
                    // Preserve document order rather than Set order.
                    ids = find(LayerQuery()).filter { inherited.contains($0) }
                }
            } else {
                ids = find(c.query, selection: selection)
            }
            if ids.isEmpty {
                report.append("\(c.summary): no matching layers")
                continue
            }
            if case .select = c {
                pendingSelection = Set(ids)
                scope = Set(ids)
            } else {
                let detail = Page.perform(c, ids: ids, to: &self)
                let count = "\(ids.count) layer\(ids.count == 1 ? "" : "s")"
                report.append("\(c.summary): \(detail ?? count)")
                continue
            }
            report.append("\(c.summary): \(ids.count) layer\(ids.count == 1 ? "" : "s")")
        }
        return CommandRun(report: report.isEmpty ? "Nothing matched." : report.joined(separator: "\n"),
                          selection: pendingSelection)
    }

    /// Split out from `run` purely so the type checker can cope — a switch this wide
    /// with closures inline defeats it.
    /// Returns a line describing what it did, when a count alone would hide the point.
    @discardableResult
    private static func perform(_ c: DocumentCommand, ids: [String], to p: inout Page) -> String? {
        let set = Set(ids)
        switch c {
        case .select:
            break   // handled by the caller; selection isn't a document change

        case .delete:
            for id in ids { p.removeLayer(id) }

        case .setFill(_, let hex):
            guard let col = SVGReader.color(hex, alpha: 1) else { return nil }
            for id in ids {
                p.updateLayer(id) { $0.style.fills = [Fill(paint: .color(col))] }
            }

        case .setStroke(_, let hex, let width):
            guard let col = SVGReader.color(hex, alpha: 1) else { return nil }
            for id in ids {
                p.updateLayer(id) { l in
                    var b = l.style.borders.first ?? Border()
                    b.color = col
                    if let w = width { b.thickness = CGFloat(w) }
                    l.style.borders = [b]
                }
            }

        case .setOpacity(_, let v):
            let clamped = max(0, min(1, CGFloat(v)))
            for id in ids { p.updateLayer(id) { $0.style.opacity = clamped } }

        case .setVisible(_, let v):
            for id in ids { p.updateLayer(id) { $0.isVisible = v } }

        case .setText(_, let text, let font, let size):
            var changed = 0
            for id in ids {
                p.updateLayer(id) { l in
                    guard case .text(var t) = l.kind else { return }
                    if let text { t.string = text }
                    if let font { t.fontName = font }
                    if let size { t.fontSize = CGFloat(size) }
                    l.kind = .text(t)
                    changed += 1
                }
            }
            return "\(changed) text layer\(changed == 1 ? "" : "s") changed"

        case .rename(_, let pattern):
            for (i, id) in ids.enumerated() {
                p.updateLayer(id) { l in
                    var out = pattern.replacingOccurrences(of: "{i}", with: String(i + 1))
                    out = out.replacingOccurrences(of: "{name}", with: l.name)
                    l.name = out
                }
            }

        case .move(_, let dx, let dy):
            for id in ids {
                p.updateLayer(id) { l in
                    l.frame.origin = CGPoint(x: l.frame.minX + CGFloat(dx),
                                             y: l.frame.minY + CGFloat(dy))
                }
            }

        case .resize(_, let w, let h):
            for id in ids {
                p.updateLayer(id) { l in
                    let newW: CGFloat = w.map { CGFloat($0) } ?? l.frame.width
                    let newH: CGFloat = h.map { CGFloat($0) } ?? l.frame.height
                    l.resize(to: CGSize(width: newW, height: newH))
                }
            }

        case .align(_, let edge):
            let map: [String: AlignEdge] = [
                "left": .left, "centre": .horizontalCentre, "center": .horizontalCentre,
                "right": .right, "top": .top, "middle": .verticalMiddle, "bottom": .bottom,
            ]
            if let e = map[edge.lowercased()] { p.align(set, to: e) }

        case .distribute(_, let axis):
            let vertical = axis.lowercased().hasPrefix("v")
            p.distribute(set, along: vertical ? .vertical : .horizontal)

        case .order(_, let dir):
            switch dir.lowercased() {
            case "front": p.bringToFront(set)
            case "back": p.sendToBack(set)
            case "forward": p.bringForward(set)
            default: p.sendBackward(set)
            }

        case .sort(_, let by):
            let n = p.sortLayers(set, by: by)
            return n > 0 ? "\(n) layer\(n == 1 ? "" : "s") reordered"
                         : "nothing to reorder — needs 2+ siblings"

        case .group(_, let gname):
            p.group(set, named: gname ?? "Group")

        case .ungroup:
            for id in ids { p.ungroup(id) }

        case .add:
            break   // handled before selector resolution

        case .simplify(_, let tolerance, let detail):
            var before = 0, after = 0, touched = 0
            for id in ids {
                guard let l = p.layer(id), case .path(let cg, let closed) = l.kind else { continue }
                // Detail is relative to the layer's own size, so one number works on a
                // 40pt icon and a 2000pt coin. Tolerance wins when both are given.
                let diagonal = hypot(l.frame.width, l.frame.height)
                let eps: CGFloat
                if let tolerance { eps = CGFloat(tolerance) }
                else if let detail { eps = max(0.01, diagonal * 0.02 * CGFloat(1 - min(1, max(0, detail)))) }
                else { eps = max(0.01, diagonal * 0.004) }

                var vp = VectorPath(cgPath: cg)
                let was = vp.points.count
                vp.simplify(tolerance: eps)
                guard vp.points.count < was else { continue }
                before += was
                after += vp.points.count
                touched += 1
                p.updateLayer(id) { $0.kind = .path(vp.cgPath(), closed: closed) }
            }
            guard touched > 0 else { return "nothing to remove" }
            let saved = before - after
            return "\(before) points → \(after) across \(touched) layer\(touched == 1 ? "" : "s") "
                 + "(\(saved * 100 / max(1, before))% fewer)"

        case .duplicate(_, let dx, let dy, let times):
            for id in ids {
                guard let original = p.layer(id) else { continue }
                for n in 1...max(1, times) {
                    var copy = original.withNewIDs()
                    copy.frame.origin = CGPoint(x: original.frame.minX + CGFloat(dx) * CGFloat(n),
                                                y: original.frame.minY + CGFloat(dy) * CGFloat(n))
                    p.layers.append(copy)
                }
            }

        case .combine(_, let op):
            if op.lowercased() == "flatten" {
                var done = 0
                for id in ids where p.flattenShape(id) { done += 1 }
                return done == 0 ? "nothing to flatten" : "\(done) shape\(done == 1 ? "" : "s")"
            }
            let mapped: BooleanOp
            switch op.lowercased() {
            case "subtract": mapped = .subtract
            case "intersect": mapped = .intersect
            case "difference": mapped = .difference
            default: mapped = .union
            }
            guard ids.count >= 2 else { return "needs at least two shapes" }
            guard p.combine(ids, op: mapped) != nil else {
                return "couldn't combine those — they may be in different containers"
            }
            return "\(ids.count) shapes into one"

        case .curve(_, let radius, let angle, let flipped):
            for id in ids {
                // A ring inside an artboard should be concentric with it. Curving in
                // place would centre the circle on wherever the text box happened to
                // sit — put the text "along the bottom" first and the ring hangs off
                // the edge and gets clipped away. `angle` is what positions it.
                let container = p.ancestors(of: id).compactMap { p.layer($0) }
                    .last(where: { $0.isArtboard })?.frame.size
                p.updateLayer(id) { l in
                    guard case .text(var run) = l.kind else { return }
                    if let radius {
                        // Editing an existing curve keeps whatever wasn't mentioned.
                        var a = run.arc ?? TextArc(radius: CGFloat(radius))
                        a.radius = max(1, CGFloat(radius))
                        if let angle { a.angle = CGFloat(angle) }
                        if let flipped { a.flipped = flipped }
                        run.arc = a
                    } else if angle != nil || flipped != nil, var a = run.arc {
                        if let angle { a.angle = CGFloat(angle) }
                        if let flipped { a.flipped = flipped }
                        run.arc = a
                    } else {
                        run.arc = nil          // straighten
                    }
                    l.kind = .text(run)
                    let curved = run.arc != nil
                    l.fitFrameToArc()
                    if curved, let container {
                        l.frame.origin = CGPoint(x: container.width / 2 - l.frame.width / 2,
                                                 y: container.height / 2 - l.frame.height / 2)
                    }
                }
            }
        }
        return nil
    }
}

/// What to create. Every field is optional with a sensible default, because a model
/// asked to "make a new artboard" shouldn't have to invent a size and position.
public struct AddSpec: Sendable, Equatable {
    public var kind: String = "rect"    // artboard | rect | ellipse | text | line
    public var name: String?
    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?
    public var fill: String?
    public var text: String?
    public var font: String?
    public var fontSize: Double?
    /// Name of an artboard or group to put it inside. Nil means the page itself.
    public var parent: String?
    /// Star points or polygon sides.
    public var sides: Int?
    /// Star only: inner radius as a fraction of the outer.
    public var innerRatio: Double?
    public init() {}
}

extension Page {
    /// Default size per kind. Artboards match the insert menu at 500×500.
    private static func defaultSize(_ kind: String) -> CGSize {
        switch kind {
        case "artboard": return CGSize(width: 500, height: 500)
        case "text":     return CGSize(width: 400, height: 70)
        default:         return CGSize(width: 200, height: 200)
        }
    }

    /// Where a new layer lands when nothing says otherwise: the middle of what's
    /// already there, so it appears on screen rather than off in the margins.
    private func defaultOrigin(for size: CGSize, in container: CGRect?) -> CGPoint {
        let b = layers.isEmpty
            ? CGRect(x: 0, y: 0, width: 1000, height: 1000)
            : contentBounds()
        return CGPoint(x: b.midX - size.width / 2, y: b.midY - size.height / 2)
    }

    /// Finds the container a new layer should go into.
    ///
    /// Not a plain name query. Asking for parent "Back" in a document that already
    /// has a "back" matched the old one and put the artwork silently in the wrong
    /// artboard — the loose substring match every other selector uses is exactly
    /// wrong here, because there's one right answer rather than a set.
    ///
    /// Exact beats case-insensitive beats substring, and within each, the LAST match
    /// wins: a model naming a parent it just created means that one, and new layers
    /// are appended.
    private func resolveParent(_ name: String) -> Layer? {
        var q = LayerQuery()
        q.name = name
        let candidates = find(q).compactMap { layer($0) }.filter {
            if case .group = $0.kind { return true }
            return false
        }
        return candidates.last(where: { $0.name == name })
            ?? candidates.last(where: { $0.name.lowercased() == name.lowercased() })
            ?? candidates.last
    }

    /// Creates a layer and returns its id.
    ///
    /// Shared by the insert menu, the chat and MCP. A model that can only modify what
    /// already exists can't answer "make a new artboard", which is the first thing
    /// anyone asks it.
    @discardableResult
    public mutating func add(_ spec: AddSpec) -> String? {
        let kind = spec.kind.lowercased()
        let d = Page.defaultSize(kind)
        let size = CGSize(width: max(1, spec.width.map { CGFloat($0) } ?? d.width),
                          height: max(1, spec.height.map { CGFloat($0) } ?? d.height))

        // Placing into an artboard positions relative to it, which is what "add a
        // circle to the front artboard" has to mean.
        let parent = spec.parent.flatMap { resolveParent($0) }
        // Coordinates are relative to whatever contains the layer. "Put a circle at
        // 100,100 in artboard Back" means 100 from the artboard's corner — subtracting
        // the artboard origin from that as well put the artwork thousands of units
        // off-page while still reporting success.
        let origin: CGPoint
        if let parent {
            origin = CGPoint(
                x: spec.x.map { CGFloat($0) } ?? (parent.frame.width - size.width) / 2,
                y: spec.y.map { CGFloat($0) } ?? (parent.frame.height - size.height) / 2)
        } else {
            let fallback = defaultOrigin(for: size, in: nil)
            origin = CGPoint(x: spec.x.map { CGFloat($0) } ?? fallback.x,
                             y: spec.y.map { CGFloat($0) } ?? fallback.y)
        }
        let frame = CGRect(origin: origin, size: size)
        let local = CGRect(origin: .zero, size: size)

        var l: Layer
        switch kind {
        case "artboard":
            l = Layer(kind: .group([]))
            l.isArtboard = true
            l.backgroundColor = Color(r: 1, g: 1, b: 1, a: 1)
        case "ellipse", "oval", "circle":
            l = Layer(kind: .path(CGPath(ellipseIn: local, transform: nil), closed: true))
        case "text":
            var run = TextRun()
            run.string = spec.text ?? "Type something"
            run.fontName = spec.font ?? "Helvetica"
            run.fontSize = spec.fontSize.map { CGFloat($0) } ?? 48
            run.alignment = .center
            l = Layer(kind: .text(run))
        case "line":
            let p = CGMutablePath()
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: size.width, y: 0))
            l = Layer(kind: .path(p, closed: false))
        case "star":
            let shape = AutoShape(kind: .star, sides: spec.sides ?? 5,
                                  innerRatio: CGFloat(spec.innerRatio ?? 0.45))
            l = Layer(kind: .path(shape.path(in: local), closed: true))
            l.autoShape = shape
        case "polygon", "hexagon", "triangle":
            let sides = spec.sides ?? (kind == "hexagon" ? 6 : kind == "triangle" ? 3 : 6)
            let shape = AutoShape(kind: .polygon, sides: sides)
            l = Layer(kind: .path(shape.path(in: local), closed: true))
            l.autoShape = shape
        default:
            l = Layer(kind: .path(CGPath(rect: local, transform: nil), closed: true))
        }

        l.name = spec.name ?? kind.prefix(1).uppercased() + kind.dropFirst()
        l.frame = frame
        if kind != "artboard" {
            let colour = spec.fill.flatMap { SVGReader.color($0, alpha: 1) } ?? .black
            if kind == "line" {
                var b = Border()
                b.color = colour
                b.thickness = 1
                l.style.borders = [b]
            } else {
                l.style.fills = [Fill(paint: .color(colour))]
            }
        } else if let hex = spec.fill, let c = SVGReader.color(hex, alpha: 1) {
            l.backgroundColor = c
        }

        if let parent, case .group(var kids) = parent.kind {
            kids.append(l)
            updateLayer(parent.id) { $0.kind = .group(kids) }
            return l.id
        }
        if kind == "artboard" {
            // Behind everything. An artboard is a backdrop with a white fill, and one
            // added in front paints straight over the artwork it was meant to hold —
            // which looks exactly like the drawing having been deleted.
            layers.insert(l, at: 0)
        } else {
            layers.append(l)
            // Nobody named a parent, so the artboard it lands on gets it. An artboard is
            // never adopted by another one: nesting them isn't a thing here.
            adoptIntoArtboard(l.id)
        }
        return l.id
    }
}
