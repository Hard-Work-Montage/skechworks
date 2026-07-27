import AccompliceCore
import SwiftUI

/// The right-hand inspector. Read-only for now, but laid out the way it needs to be
/// once these become fields — one row per property, grouped the way Sketch and Figma
/// group them, so editing drops in without a redesign.
struct PropertiesPanel: View {
    @EnvironmentObject var store: DocumentStore
    let layer: Layer?
    let pageName: String?
    var selectionCount: Int = 0

    var body: some View {
        Group {
            if let layer {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(layer)
                        Divider()
                        geometry(layer)
                        if !layer.style.fills.isEmpty { Divider(); fills(layer) }
                        if !layer.style.borders.isEmpty { Divider(); borders(layer) }
                        if !layer.style.shadows.isEmpty { Divider(); shadows(layer) }
                        if case .text(let t) = layer.kind { Divider(); text(t, layer) }
                        if let pt = store.editingPoint { Divider(); pointType(pt) }
                        if case .shapeGroup(let kids, let rule) = layer.kind {
                            Divider(); combined(kids.count, rule, layer)
                        }
                    }
                    .padding(14)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: selectionCount > 1 ? "square.on.square" : "sidebar.right")
                        .font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(selectionCount > 1 ? "\(selectionCount) layers selected" : "No selection")
                        .foregroundStyle(.secondary)
                    Text(pageName.map { "on \($0)" } ?? "")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Sections

    private func header(_ l: Layer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(l)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(l.name.isEmpty ? kind(l) : l.name)
                    .font(.headline).lineLimit(1)
                Text(kind(l)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !l.isVisible {
                Image(systemName: "eye.slash").foregroundStyle(.tertiary).help("Hidden")
            }
        }
    }

    private func geometry(_ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Position & Size")
            // Two even columns throughout, so every field lines up regardless of how
            // long its label is. A fixed label column is what stops "Opacity" wrapping
            // onto a second line and shoving its field out of alignment.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    editable("X", l.frame.minX, l) { layer, v in layer.frame.origin.x = v }
                    editable("Y", l.frame.minY, l) { layer, v in layer.frame.origin.y = v }
                }
                GridRow {
                    editable("W", l.frame.width, l) { layer, v in
                        layer.resize(to: CGSize(width: max(1, v), height: layer.frame.height))
                    }
                    editable("H", l.frame.height, l) { layer, v in
                        layer.resize(to: CGSize(width: layer.frame.width, height: max(1, v)))
                    }
                }
                GridRow {
                    editable("Opacity", l.style.opacity * 100, l, suffix: "%") { layer, v in
                        layer.style.opacity = max(0, min(1, v / 100))
                    }
                    if l.rotation != 0 {
                        field("Angle", l.rotation, suffix: "°")
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
            }
            Toggle("Visible", isOn: Binding(
                get: { l.isVisible },
                set: { on in
                    guard on != l.isVisible else { return }   // no-op sets must not dirty the document
                    store.edit(l.id, actionName: on ? "Show Layer" : "Hide Layer") { $0.isVisible = on }
                }
            ))
            .toggleStyle(.checkbox).font(.callout).padding(.top, 2)
            if l.flipH || l.flipV {
                Text([l.flipH ? "Flipped horizontally" : nil,
                      l.flipV ? "Flipped vertically" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if l.booleanOp != .none {
                row("Boolean", boolName(l.booleanOp))
            }
            if l.hasClippingMask { row("Mask", "Clips layers above") }
            if l.isArtboard {
                Divider().padding(.vertical, 2)
                sectionTitle("Artboard")
                if let bg = l.backgroundColor {
                    HStack(spacing: 8) {
                        swatch(bg)
                        Text(bg.hex.uppercased()).font(.system(.body, design: .monospaced))
                        Spacer()
                    }
                }
                // Sketch's "Include in export" checkbox. The coin front/back artboards
                // keep this off: white while you work, transparent when engraved.
                Toggle("Include fill in export", isOn: Binding(
                    get: { l.backgroundInExport },
                    set: { on in
                        guard on != l.backgroundInExport else { return }
                        store.edit(l.id, actionName: on ? "Include Artboard Fill" : "Exclude Artboard Fill") {
                            $0.backgroundInExport = on
                        }
                    }
                ))
                .toggleStyle(.checkbox).font(.callout)
                .disabled(l.backgroundColor == nil)
            }
        }
    }

    private func fills(_ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Fill")
            ForEach(Array(l.style.fills.enumerated()), id: \.offset) { _, f in
                switch f.paint {
                case .color(let c):
                    HStack(spacing: 8) {
                        swatch(c)
                        Text(c.hex.uppercased()).font(.system(.body, design: .monospaced))
                        Spacer()
                        if c.a != 1 {
                            Text("\(Int(c.a * 100))%").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .gradient(let g):
                    HStack(spacing: 8) {
                        LinearGradient(colors: g.stops.map { Color(nsColor: NSColor(cgColor: $0.color.cg) ?? .black) },
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                        Text("\(["Linear", "Radial", "Angular"][g.kind.rawValue]) · \(g.stops.count) stops")
                        Spacer()
                    }
                }
            }
        }
    }

    private func borders(_ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Border")
            ForEach(Array(l.style.borders.enumerated()), id: \.offset) { _, b in
                HStack(spacing: 8) {
                    swatch(b.color)
                    Text(b.color.hex.uppercased()).font(.system(.body, design: .monospaced))
                    Spacer()
                    Text("\(trim(b.thickness))pt")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(["Center", "Inside", "Outside"][b.position.rawValue])
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !b.dashPattern.isEmpty {
                    Text("Dashed · \(b.dashPattern.map(trim).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func shadows(_ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Shadow")
            ForEach(Array(l.style.shadows.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 8) {
                    swatch(s.color)
                    Text("\(trim(s.offset.width)), \(trim(s.offset.height))")
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text("blur \(trim(s.blur))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func text(_ t: TextRun, _ layer: Layer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Text")
            row("Font", t.fontName)
            row("Size", "\(trim(t.fontSize))")
            row("Align", ["Left", "Right", "Center", "Justified"][alignIndex(t)])
            if t.lineHeight > 0 { row("Line height", trim(t.lineHeight)) }
            if t.kerning != 0 { row("Kerning", trim(t.kerning)) }
            Text(t.string)
                .font(.caption).foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
            curve(t, layer)
        }
    }

    /// Bending text round a circle: a radius and an angle, not a path to attach to.
    private func curve(_ t: TextRun, _ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Toggle("Curve", isOn: Binding(
                get: { t.arc != nil },
                set: { on in
                    guard on != (t.arc != nil) else { return }   // SwiftUI re-sets unchanged values
                    store.edit(l.id, actionName: on ? "Curve Text" : "Straighten Text") { layer in
                        guard case .text(var run) = layer.kind else { return }
                        // Default to a ring that fits the layer, so switching it on
                        // shows something sensible rather than nothing.
                        run.arc = on
                            ? TextArc(radius: min(layer.frame.width, layer.frame.height) / 2)
                            : nil
                        layer.kind = .text(run)
                        layer.fitFrameToArc()
                    }
                }))
                .toggleStyle(.switch).controlSize(.mini)
                .font(.callout)

            if let arc = t.arc {
                editable("Radius", arc.radius, l) { layer, v in
                    guard case .text(var run) = layer.kind else { return }
                    run.arc?.radius = max(1, v)
                    layer.kind = .text(run)
                    layer.fitFrameToArc()
                }
                editable("Angle", arc.angle, l, suffix: "°") { layer, v in
                    guard case .text(var run) = layer.kind else { return }
                    run.arc?.angle = v
                    layer.kind = .text(run)
                }
                Toggle("Flip (read upright below)", isOn: Binding(
                    get: { arc.flipped },
                    set: { f in
                        guard f != arc.flipped else { return }
                        store.edit(l.id, actionName: "Flip Curve") { layer in
                            guard case .text(var run) = layer.kind else { return }
                            run.arc?.flipped = f
                            layer.kind = .text(run)
                        }
                    }))
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.callout)
            }
        }
    }

    /// Sketch's four point types, where they belong: on the point, not in the toolbar.
    ///
    /// Words, not glyphs. Four handle diagrams at 14pt are indistinguishable — Sketch's
    /// own are, which is why it needs a tooltip on each to tell you what you're
    /// looking at. A control you have to hover to read isn't doing its job.
    ///
    /// The names are one word each so four fit the column; the tooltips carry Sketch's
    /// exact phrasing, so what you already know still maps.
    private func pointType(_ pt: DocumentStore.EditingPoint) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Point Type")
            Picker("", selection: Binding(
                get: { pt.mode },
                set: { m in if m != pt.mode { store.setPointMode(m) } }
            )) {
                ForEach(CurveMode.allCases, id: \.self) { m in
                    Text(Self.pointTypeName(m)).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            Text(Self.pointTypeHint(pt.mode))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func pointTypeName(_ m: CurveMode) -> String {
        switch m {
        case .straight: return "Straight"
        case .mirrored: return "Mirrored"
        case .asymmetric: return "Aligned"
        case .disconnected: return "Free"
        }
    }

    private static func pointTypeHint(_ m: CurveMode) -> String {
        switch m {
        case .straight: return "No handles — a corner."
        case .mirrored: return "Mirror angle and length."
        case .asymmetric: return "Mirror angle, lengths independent."
        case .disconnected: return "Handles fully independent."
        }
    }

    private func combined(_ count: Int, _ rule: WindingRule, _ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Combined Shape")
            row("Children", "\(count)")
            row("Winding", rule == .evenOdd ? "Even-odd" : "Non-zero")
        }
    }

    // MARK: - Bits

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased()).font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary).tracking(0.6)
            .padding(.bottom, 1)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).lineLimit(1)
        }
        .font(.callout)
    }

    /// A number you can type into. Commits on Return or focus loss, and each commit
    /// is one undo step — so holding a key in the field doesn't bury the undo stack.
    private func editable(_ label: String, _ value: CGFloat, _ l: Layer,
                          suffix: String = "",
                          apply: @escaping (inout Layer, CGFloat) -> Void) -> some View {
        NumberField(label: label, value: value, suffix: suffix) { newValue in
            store.edit(l.id, actionName: "Change \(label)") { apply(&$0, newValue) }
        }
    }

    private func field(_ label: String, _ value: CGFloat, suffix: String = "") -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: FieldMetrics.labelWidth, alignment: .leading)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Text(trim(value) + suffix)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private func swatch(_ c: AccompliceCore.Color) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(SwiftUI.Color(nsColor: NSColor(cgColor: c.cg) ?? .black))
            .frame(width: 22, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
    }

    private func trim(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private func alignIndex(_ t: TextRun) -> Int {
        switch t.alignment {
        case .right: return 1
        case .center: return 2
        case .justified: return 3
        default: return 0
        }
    }

    private func boolName(_ b: BooleanOp) -> String {
        ["None", "Union", "Subtract", "Intersect", "Difference"][b.rawValue + 1]
    }

    private func kind(_ l: Layer) -> String {
        switch l.kind {
        case .group: return l.isArtboard ? "Artboard" : "Group"
        case .shapeGroup: return "Combined Shape"
        case .path(_, let closed): return closed ? "Path" : "Open Path"
        case .text: return "Text"
        case .bitmap: return "Image"
        }
    }

    private func icon(_ l: Layer) -> String {
        switch l.kind {
        case .group: return l.isArtboard ? "rectangle.dashed" : "folder"
        case .shapeGroup: return "square.on.circle"
        case .path: return "scribble"
        case .text: return "textformat"
        case .bitmap: return "photo"
        }
    }
}

// MARK: - Lookup

enum LayerLookup {
    /// Finds a layer anywhere in the tree by id.
    static func find(_ id: String, in layers: [Layer]) -> Layer? {
        for l in layers {
            if l.id == id { return l }
            let kids: [Layer]
            switch l.kind {
            case .group(let k): kids = k
            case .shapeGroup(let k, _): kids = k
            default: kids = []
            }
            if let hit = find(id, in: kids) { return hit }
        }
        return nil
    }
}


/// Text field that only reports a value when it's actually committed, and that
/// re-syncs from the model when the selection or an undo changes it underneath.
/// Shared so typed fields and read-only ones line up on the same grid.
enum FieldMetrics {
    static let labelWidth: CGFloat = 46
}

private struct NumberField: View {
    let label: String
    let value: CGFloat
    var suffix: String = ""
    let onCommit: (CGFloat) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: FieldMetrics.labelWidth, alignment: .leading)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onChange(of: value) { _, _ in if !focused { text = format(value) } }
                .onAppear { text = format(value) }
        }
    }

    private func commit() {
        guard let v = Double(text.replacingOccurrences(of: suffix, with: "")
            .trimmingCharacters(in: .whitespaces)) else {
            text = format(value); return          // reject junk, restore what was there
        }
        if CGFloat(v) != value { onCommit(CGFloat(v)) }
        text = format(CGFloat(v))
    }

    private func format(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
