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
            let ids: [String]
            if c.query.isEmpty {
                guard let inherited = scope, !inherited.isEmpty else {
                    report.append("\(c.summary): refused — no layers specified")
                    continue
                }
                // Preserve document order rather than Set order.
                ids = find(LayerQuery()).filter { inherited.contains($0) }
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
                Page.perform(c, ids: ids, to: &self)
            }
            report.append("\(c.summary): \(ids.count) layer\(ids.count == 1 ? "" : "s")")
        }
        return CommandRun(report: report.isEmpty ? "Nothing matched." : report.joined(separator: "\n"),
                          selection: pendingSelection)
    }

    /// Split out from `run` purely so the type checker can cope — a switch this wide
    /// with closures inline defeats it.
    private static func perform(_ c: DocumentCommand, ids: [String], to p: inout Page) {
        let set = Set(ids)
        switch c {
        case .select:
            break   // handled by the caller; selection isn't a document change

        case .delete:
            for id in ids { p.removeLayer(id) }

        case .setFill(_, let hex):
            guard let col = SVGReader.color(hex, alpha: 1) else { return }
            for id in ids {
                p.updateLayer(id) { $0.style.fills = [Fill(paint: .color(col))] }
            }

        case .setStroke(_, let hex, let width):
            guard let col = SVGReader.color(hex, alpha: 1) else { return }
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

        case .group(_, let gname):
            p.group(set, named: gname ?? "Group")

        case .ungroup:
            for id in ids { p.ungroup(id) }

        case .curve(_, let radius, let angle, let flipped):
            for id in ids {
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
                }
            }
        }
    }
}
