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
                    VStack(alignment: .leading, spacing: 14) {
                        header(layer)
                        Divider()
                        geometry(layer)
                        if !layer.style.fills.isEmpty { Divider(); fills(layer) }
                        if !layer.style.borders.isEmpty { Divider(); borders(layer) }
                        if !layer.style.shadows.isEmpty { Divider(); shadows(layer) }
                        if case .text(let t) = layer.kind { Divider(); text(t) }
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
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Position & Size")
            HStack(spacing: 10) {
                editable("X", l.frame.minX, l) { layer, v in layer.frame.origin.x = v }
                editable("Y", l.frame.minY, l) { layer, v in layer.frame.origin.y = v }
            }
            HStack(spacing: 10) {
                editable("W", l.frame.width, l) { layer, v in
                    layer.resize(to: CGSize(width: max(1, v), height: layer.frame.height))
                }
                editable("H", l.frame.height, l) { layer, v in
                    layer.resize(to: CGSize(width: layer.frame.width, height: max(1, v)))
                }
            }
            HStack(spacing: 10) {
                editable("Opacity", l.style.opacity * 100, l, suffix: "%") { layer, v in
                    layer.style.opacity = max(0, min(1, v / 100))
                }
                if l.rotation != 0 { field("Rotation", l.rotation, suffix: "°") }
            }
            Toggle("Visible", isOn: Binding(
                get: { l.isVisible },
                set: { on in
                    guard on != l.isVisible else { return }   // no-op sets must not dirty the document
                    store.edit(l.id, actionName: on ? "Show Layer" : "Hide Layer") { $0.isVisible = on }
                }
            ))
            .toggleStyle(.checkbox).font(.callout)
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

    private func text(_ t: TextRun) -> some View {
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
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
            Text(trim(value) + suffix)
                .font(.system(.callout, design: .monospaced))
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
private struct NumberField: View {
    let label: String
    let value: CGFloat
    var suffix: String = ""
    let onCommit: (CGFloat) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
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
