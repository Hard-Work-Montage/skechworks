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
                        if roundableCorners(layer) > 0 { Divider(); corners(layer) }
                        if layer.autoShape != nil { Divider(); autoShapeSection(layer) }
                        // Shown whenever the layer can take paint, not only when it
                        // already has some — the + button that ADDS the first fill or
                        // border lives inside these sections, so hiding them empty
                        // left no way to add a border from the panel at all.
                        if paintable(layer) { Divider(); fills(layer) }
                        if paintable(layer) { Divider(); borders(layer) }
                        if case .bitmap = layer.kind {
                            Divider(); imageSection(layer)
                            Divider(); eraser(layer)
                        }
                        // Always, since adding one starts here — except artboards,
                        // which don't cast shadows.
                        if !layer.isArtboard { Divider(); shadows(layer) }
                        if case .text(let t) = layer.kind { Divider(); text(t, layer) }
                        if let pt = store.editingPoint { Divider(); pointType(pt) }
                        if case .shapeGroup(let kids, let rule) = layer.kind {
                            Divider(); combined(kids.count, rule, layer)
                        }
                        // Last, where Sketch keeps it — the inspector is where people
                        // look for export, not the File menu.
                        Divider(); exportSection(layer)
                    }
                    .padding(14)
                    // Fields are freshly built per layer. Reused ones carry @State
                    // (a half-typed hex, an editing flag) from the layer before,
                    // and that state leaking across a selection change is how one
                    // shape ended up wearing another's colour.
                    .id(layer.id)
                }
            } else if selectionCount > 1 {
                ScrollView {
                    multi(selectedLayers)
                        .padding(14)
                        // Same reasoning as the single-layer id: fields must not
                        // carry state from one selection to the next.
                        .id(store.selection.sorted().joined(separator: "·"))
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("No selection")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("selection-summary")
                    Text(pageName.map { "on \($0)" } ?? "")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Multi-selection

    private var selectedLayers: [Layer] {
        store.selection.compactMap { store.page?.layer($0) }
    }

    /// The value the whole selection agrees on, or nil — which the fields render
    /// as "Mixed", the way Sketch does.
    private func common<T: Equatable>(_ read: (Layer) -> T) -> T? {
        let values = selectedLayers.map(read)
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// Like `editable`, but writing puts every selected layer on the typed value —
    /// so X aligns them, W sizes them, Opacity fades them together.
    private func multiEditable(_ label: String, _ value: CGFloat?, suffix: String = "",
                               apply: @escaping (inout Layer, CGFloat) -> Void) -> some View {
        NumberField(label: label, value: value, suffix: suffix) { [ids = Array(store.selection)] v in
            store.edit(ids, actionName: "Change \(label)") { apply(&$0, v) }
        }
    }

    private func multi(_ layers: [Layer]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "square.on.square").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(layers.count) layers")
                        .font(.headline)
                        .accessibilityIdentifier("selected-layer")
                    Text(pageName.map { "on \($0)" } ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Position & Size")
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    GridRow {
                        multiEditable("X", common { $0.frame.minX }) { l, v in l.frame.origin.x = v }
                        multiEditable("Y", common { $0.frame.minY }) { l, v in l.frame.origin.y = v }
                    }
                    GridRow {
                        multiEditable("W", common { $0.frame.width }) { l, v in
                            l.resize(to: CGSize(width: max(1, v), height: l.frame.height))
                        }
                        multiEditable("H", common { $0.frame.height }) { l, v in
                            l.resize(to: CGSize(width: l.frame.width, height: max(1, v)))
                        }
                    }
                    GridRow {
                        multiEditable("Opacity", common { $0.style.opacity * 100 }, suffix: "%") { l, v in
                            l.style.opacity = max(0, min(1, v / 100))
                        }
                        multiEditable("Angle", common { $0.rotation }, suffix: "°") { l, v in
                            l.rotation = v.truncatingRemainder(dividingBy: 360)
                        }
                    }
                }
            }
            // Only when the whole selection can wear one: a photo has no fill row
            // to change, and quietly skipping it would make "set them all" a lie.
            if layers.allSatisfy({ solidFill($0) != nil }) {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Fill")
                    if common({ solidFill($0).map { "\($0.hex)/\($0.a)" } }) != nil,
                       let c = layers.first.flatMap(solidFill) {
                        ColorField(color: c) { applyFill($0) }
                    } else {
                        // Sketch's "Mixed": the swatch opens on the front-most
                        // layer's colour, and picking one brings the rest to it.
                        HStack(spacing: 8) {
                            ColorPopoverButton(color: layers.first.flatMap(solidFill)
                                                ?? Color(r: 0, g: 0, b: 0, a: 1)) { applyFill($0) }
                            Text("Mixed")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func solidFill(_ l: Layer) -> AccompliceCore.Color? {
        guard let f = l.style.fills.first, case .color(let c) = f.paint else { return nil }
        return c
    }

    private func applyFill(_ c: AccompliceCore.Color) {
        store.edit(Array(store.selection), actionName: "Change Fill",
                   coalescingAs: "multiFill:\(store.selection.sorted().joined())") { l in
            guard !l.style.fills.isEmpty, case .color = l.style.fills[0].paint else { return }
            l.style.fills[0].paint = .color(c)
        }
    }

    // MARK: - Sections

    private func header(_ l: Layer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(l)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                // What the UI tests read to find out what's selected.
                Text(l.name.isEmpty ? kind(l) : l.name)
                    .font(.headline).lineLimit(1)
                    .accessibilityIdentifier("selected-layer")
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
                    // Always here, not only once something has been rotated. It was
                    // read-only, so a layer could arrive rotated from Sketch and there
                    // was no way to change it — or to nudge a photo by a degree.
                    editable("Angle", l.rotation, l, suffix: "°") { layer, v in
                        layer.rotation = v.truncatingRemainder(dividingBy: 360)
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
            if l.booleanOp != .none || isInsideCombinedShape(l) {
                // Editable, because the whole point of a combined shape being made of
                // its parts is that you can change your mind about how they combine.
                Picker("Boolean", selection: Binding(
                    get: { l.booleanOp },
                    set: { if $0 != l.booleanOp { store.setBooleanOp(l.id, to: $0) } }
                )) {
                    Text("None").tag(BooleanOp.none)
                    Text("Union").tag(BooleanOp.union)
                    Text("Subtract").tag(BooleanOp.subtract)
                    Text("Intersect").tag(BooleanOp.intersect)
                    Text("Difference").tag(BooleanOp.difference)
                }
                .font(.callout)
            }
            if l.hasClippingMask { row("Mask", "Clips layers above") }
            if l.isArtboard {
                Divider().padding(.vertical, 2)
                sectionTitle("Artboard")
                ColorField(color: l.backgroundColor ?? Color(r: 1, g: 1, b: 1, a: 1)) {
                    store.setArtboardBackground(l.id, to: $0)
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

    /// One format, one scale, one button — the panel version of File ▸ Export
    /// Selected. The full per-preset list Sketch grew can come later if it earns it.
    @State private var exportFormat: DocumentStore.ExportFormat = .svg
    @State private var exportScale: CGFloat = 1

    private func exportSection(_ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Export")
            HStack(spacing: 8) {
                Picker("", selection: $exportFormat) {
                    ForEach(DocumentStore.ExportFormat.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 150)
                Picker("", selection: $exportScale) {
                    ForEach([1, 2, 3], id: \.self) { s in
                        Text("\(s)x").tag(CGFloat(s))
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .disabled(exportFormat == .svg)
                Spacer()
            }
            Button {
                store.exportSelected(format: exportFormat, scale: exportScale)
            } label: {
                Text("Export \(l.isArtboard ? "Artboard" : kind(l))…")
                    .frame(maxWidth: .infinity)
            }
            Text(exportFormat == .svg
                 ? "Vectors have no pixels — scale doesn't apply."
                 : "Sized to this \(l.isArtboard ? "artboard" : "layer"), at \(Int(exportScale))x.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A star or polygon stays a recipe: change the numbers, the shape re-draws.
    /// Fireworks called these Auto Shapes, and they were the point.
    private func autoShapeSection(_ l: Layer) -> some View {
        let a = l.autoShape!
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle(a.kind == .star ? "Star" : "Polygon")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    NumberField(label: a.kind == .star ? "Points" : "Sides",
                                value: CGFloat(a.sides)) { v in
                        store.setAutoShape(l.id, sides: Int(v))
                    }
                    if a.kind == .star {
                        NumberField(label: "Inner", value: a.innerRatio * 100, suffix: "%") { v in
                            store.setAutoShape(l.id, innerRatio: v / 100)
                        }
                    }
                }
            }
            Text(a.kind == .star
                 ? "How many spikes, and how deep they cut."
                 : "How many sides.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Corner radius, and which kind of corner.
    ///
    /// Only on a shape that has a straight-to-straight corner to take off, which is why
    /// it doesn't appear on a circle or on a trace made entirely of curves — a radius
    /// field that provably can't do anything is worse than no field.
    private func corners(_ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Corners")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    editable("Radius", l.cornerRadius, l) { layer, v in
                        layer.cornerRadius = max(0, v)
                    }
                    Picker("", selection: Binding(
                        get: { l.cornerStyle },
                        set: { if $0 != l.cornerStyle { store.setCornerStyle(l.id, to: $0) } }
                    )) {
                        ForEach(CornerStyle.allCases, id: \.self) { s in
                            Label { Text(s.name) } icon: { Image(nsImage: CornerGlyph.image(s)) }
                                .tag(s)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .disabled(l.cornerRadius <= 0)
                }
            }
            Text(l.cornerStyle == .smooth
                 ? "Eases into the corner, like an app icon."
                 : "A circular arc.")
                .font(.caption).foregroundStyle(.secondary)
            if roundableCorners(l) < (l.pointCount ?? 0) {
                // Otherwise the radius looks broken on a shape that's part curves: the
                // straight corners take it and the rest never will.
                let n = roundableCorners(l)
                Text("\(n) corner\(n == 1 ? "" : "s") to round — the rest are already curved.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func roundableCorners(_ l: Layer) -> Int {
        guard case .path(let p, _) = l.kind else { return 0 }
        return Corners.roundableCorners(in: p)
    }

    /// Layers whose geometry can carry a fill or border. Artboards paint their
    /// background through their own section, and bitmaps are pixels.
    private func paintable(_ l: Layer) -> Bool {
        if l.isArtboard { return false }
        switch l.kind {
        case .path, .shapeGroup, .text: return true
        default: return !l.style.fills.isEmpty || !l.style.borders.isEmpty
        }
    }

    private func fills(_ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Fill")
                Spacer()
                Button { store.addFill(l.id) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Add a fill")
            }
            ForEach(Array(l.style.fills.enumerated()), id: \.offset) { i, f in
                switch f.paint {
                case .color(let c):
                    HStack(spacing: 8) {
                        ColorField(color: c) { store.setFillColor(l.id, at: i, to: $0) }
                        removeButton("Remove fill") { store.removeFill(l.id, at: i) }
                    }
                case .gradient(let g):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            LinearGradient(colors: g.stops.map { SwiftUI.Color(nsColor: $0.color.nsColor) },
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 44, height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                            Text("\(["Linear", "Radial", "Angular"][g.kind.rawValue])")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            removeButton("Remove fill") { store.removeFill(l.id, at: i) }
                        }
                        // One row per stop. Positions aren't draggable yet — this is
                        // recolouring an existing gradient, not authoring a new one.
                        ForEach(Array(g.stops.enumerated()), id: \.offset) { j, stop in
                            HStack(spacing: 8) {
                                Text("\(Int(stop.position * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 34, alignment: .trailing)
                                ColorField(color: stop.color) {
                                    store.setGradientStopColor(l.id, fill: i, stop: j, to: $0)
                                }
                            }
                        }
                        .padding(.leading, 4)
                    }
                }
            }
            if l.style.fills.isEmpty {
                Text("No fill").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func borders(_ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Border")
                Spacer()
                Button { store.addBorder(l.id) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Add a border")
            }
            ForEach(Array(l.style.borders.enumerated()), id: \.offset) { i, b in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ColorField(color: b.color) { store.setBorderColor(l.id, at: i, to: $0) }
                        removeButton("Remove border") { store.removeBorder(l.id, at: i) }
                    }
                    HStack(spacing: 8) {
                        numberField("Width", b.thickness) { store.setBorderThickness(l.id, at: i, to: $0) }
                        Picker("", selection: Binding(
                            get: { b.position },
                            set: { store.setBorderPosition(l.id, at: i, to: $0) }
                        )) {
                            Text("Center").tag(BorderPosition.center)
                            Text("Inside").tag(BorderPosition.inside)
                            Text("Outside").tag(BorderPosition.outside)
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 92)
                    }
                    if !b.dashPattern.isEmpty {
                        Text("Dashed · \(b.dashPattern.map(trim).joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if i < l.style.borders.count - 1 { Divider() }
            }
            if l.style.borders.isEmpty {
                Text("No border").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func removeButton(_ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus") }
            .buttonStyle(.plain).foregroundStyle(.tertiary).help(help)
    }

    private func numberField(_ label: String, _ value: CGFloat,
                             _ set: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: Binding(get: { Double(value) }, set: { set(CGFloat($0)) }),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
        }
    }

    /// Shadows, editable, and reachable on anything — including a group, where the
    /// shadow comes from the silhouette of everything inside it.
    ///
    /// Both X/Y and angle/distance are shown, each driving the other. X/Y is what the
    /// format stores and what every other tool speaks, so it stays; but nobody thinks
    /// "negative four on Y" when they want the light coming from above, and for a coin
    /// sitting on a surface the angle is the thing you actually reason about.
    private func shadows(_ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Shadow")
                Spacer()
                Button { store.addShadow(l.id) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Add a shadow")
            }
            ForEach(Array(l.style.shadows.enumerated()), id: \.offset) { i, s in
                shadowEditor(l, i, s)
                if i < l.style.shadows.count - 1 { Divider() }
            }
            if l.style.shadows.isEmpty {
                Text("No shadow").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func shadowEditor(_ l: Layer, _ i: Int, _ s: Shadow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                ColorField(color: s.color) { c in
                    store.editShadow(l.id, at: i, actionName: "Change Shadow Colour",
                                     coalescingAs: "shadow:\(l.id):\(i)") { $0.color = c }
                }
                removeButton("Remove shadow") { store.removeShadow(l.id, at: i) }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    shadowField("X", s.offset.width, l, i) { $0.offset.width = $1 }
                    shadowField("Y", s.offset.height, l, i) { $0.offset.height = $1 }
                }
                GridRow {
                    shadowField("Blur", s.blur, l, i) { $0.blur = max(0, $1) }
                    shadowField("Spread", s.spread, l, i) { $0.spread = $1 }
                }
                GridRow {
                    // Angle is clockwise from straight up, so 180 is a shadow cast
                    // downward — a thing lit from above, which is the usual case.
                    shadowField("Angle", shadowAngle(s), l, i, suffix: "°") { sh, v in
                        let d = hypot(sh.offset.width, sh.offset.height)
                        let r = v * .pi / 180
                        sh.offset = CGSize(width: sin(r) * d, height: -cos(r) * d)
                    }
                    shadowField("Distance", hypot(s.offset.width, s.offset.height), l, i) { sh, v in
                        let a = shadowAngleOf(sh) * .pi / 180
                        sh.offset = CGSize(width: sin(a) * v, height: -cos(a) * v)
                    }
                }
            }
        }
    }

    private func shadowAngle(_ s: Shadow) -> CGFloat { shadowAngleOf(s) }

    /// Clockwise degrees from straight up. Zero distance has no angle, so keep the
    /// common one rather than snapping the field to something arbitrary.
    private func shadowAngleOf(_ s: Shadow) -> CGFloat {
        if abs(s.offset.width) < 0.001 && abs(s.offset.height) < 0.001 { return 180 }
        let a = atan2(s.offset.width, -s.offset.height) * 180 / .pi
        return a < 0 ? a + 360 : a
    }

    private func shadowField(_ label: String, _ value: CGFloat, _ l: Layer, _ i: Int,
                             suffix: String = "",
                             apply: @escaping (inout Shadow, CGFloat) -> Void) -> some View {
        NumberField(label: label, value: value, suffix: suffix) { v in
            store.editShadow(l.id, at: i, actionName: "Change \(label)") { apply(&$0, v) }
        }
    }

    @State private var textDraft = ""
    @FocusState private var textDraftFocused: Bool

    private func text(_ t: TextRun, _ layer: Layer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Text")
            // The string itself. Fireworks users change template text all day —
            // this being read-only was the single biggest hole in the panel.
            TextField("Text", text: $textDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .font(.callout)
                .focused($textDraftFocused)
                .onAppear { textDraft = t.string }
                .onChange(of: t.string) { _, s in if !textDraftFocused { textDraft = s } }
                .onSubmit { commitTextString(layer.id, t) }
                .onChange(of: textDraftFocused) { _, f in
                    if !f { commitTextString(layer.id, t) }
                }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    fontPicker(t, layer)
                    editableText("Size", t.fontSize, layer) { run, v in
                        run.fontSize = max(1, v)
                    }
                }
                GridRow {
                    editableText("Kern", t.kerning, layer) { run, v in run.kerning = v }
                    editableText("Line", t.lineHeight, layer) { run, v in
                        run.lineHeight = max(0, v)
                    }
                }
            }
            Picker("", selection: Binding(
                get: { alignIndex(t) },
                set: { i in
                    let all: [CTTextAlignment] = [.left, .right, .center, .justified]
                    store.editText(layer.id, "Align Text") { $0.alignment = all[i] }
                }
            )) {
                Image(systemName: "text.alignleft").tag(0)
                Image(systemName: "text.aligncenter").tag(2)
                Image(systemName: "text.alignright").tag(1)
                Image(systemName: "text.justify").tag(3)
            }
            .labelsHidden().pickerStyle(.segmented)
            curve(t, layer)
        }
    }

    private func commitTextString(_ id: String, _ t: TextRun) {
        let s = textDraft
        guard s != t.string, !s.isEmpty else { return }
        store.editText(id, "Edit Text") { $0.string = s }
    }

    /// A number field that writes into the layer's text run.
    private func editableText(_ label: String, _ value: CGFloat, _ l: Layer,
                              apply: @escaping (inout TextRun, CGFloat) -> Void) -> some View {
        NumberField(label: label, value: value) { v in
            store.editText(l.id, "Change \(label)") { apply(&$0, v) }
        }
    }

    /// Every family installed, with the current one checked. A font a designer owns
    /// is a font they might use — no curated shortlist.
    private func fontPicker(_ t: TextRun, _ l: Layer) -> some View {
        HStack(spacing: 5) {
            Text("Font")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: FieldMetrics.labelWidth, alignment: .leading)
            Menu {
                ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { fam in
                    Button {
                        store.editText(l.id, "Change Font") { $0.fontName = fam }
                    } label: {
                        if fam == t.fontName { Label(fam, systemImage: "checkmark") }
                        else { Text(fam) }
                    }
                }
            } label: {
                Text(t.fontName)
                    .font(.callout).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button).buttonStyle(.bordered)
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

    /// Whether this layer is a member of a combined shape, and so has an operation
    /// worth showing even when it's currently None.
    private func isInsideCombinedShape(_ l: Layer) -> Bool {
        guard let page = store.page else { return false }
        for id in page.ancestors(of: l.id) {
            if case .shapeGroup = page.layer(id)?.kind { return true }
        }
        return false
    }

    /// Brush settings, and the way back.
    ///
    /// Only on a bitmap, because there is nothing to rub out of a vector shape.
    /// The photo half of "quick photo work": crop and correct, without ever
    /// touching the pixels underneath.
    private func imageSection(_ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Image")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    editable("Bright", l.brightness * 100, l) { layer, v in
                        layer.brightness = min(1, max(-1, v / 100))
                    }
                    editable("Contrast", l.contrast * 100, l, suffix: "%") { layer, v in
                        layer.contrast = min(4, max(0.25, v / 100))
                    }
                }
                GridRow {
                    editable("Sat", l.saturation * 100, l, suffix: "%") { layer, v in
                        layer.saturation = min(2, max(0, v / 100))
                    }
                    Button(store.croppingID == l.id ? "Cropping… (⏎ / esc)" : "Crop") {
                        store.croppingID = store.croppingID == l.id ? nil : l.id
                    }
                    .font(.callout)
                }
            }
            HStack {
                if l.brightness != 0 || l.contrast != 1 || l.saturation != 1 {
                    Button("Reset colour") {
                        store.edit(l.id, actionName: "Reset Adjustments") {
                            $0.brightness = 0; $0.contrast = 1; $0.saturation = 1
                        }
                    }
                    .font(.caption)
                }
                if l.cropRect != nil {
                    Button("Remove crop") { store.removeCrop(l.id) }
                        .font(.caption)
                }
            }
        }
    }

    private func eraser(_ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Eraser")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    NumberField(label: "Size", value: CGFloat(store.eraseRadius)) {
                        store.eraseRadius = Double(max(1, $0))
                    }
                    NumberField(label: "Soft", value: CGFloat(store.eraseSoftness * 100), suffix: "%") {
                        store.eraseSoftness = Double(min(100, max(0, $0)) / 100)
                    }
                }
            }
            if l.erased.isEmpty {
                Text("Press E, then paint over the image.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                HStack {
                    Text("\(l.erased.count) stroke\(l.erased.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore") {
                        store.selection = [l.id]
                        store.clearErasing()
                    }
                    .font(.callout)
                    .help("Bring the whole image back. Nothing was ever removed from it.")
                }
            }
        }
    }

    private func combined(_ count: Int, _ rule: WindingRule, _ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Combined Shape")
            row("Shapes", "\(count)")
            row("Winding", rule == .evenOdd ? "Even-odd" : "Non-zero")
            Button("Flatten to One Path") {
                store.selection = [l.id]
                store.flattenSelection()
            }
            .font(.callout)
            .help("Replace the group with the single path it draws. The parts are lost.")
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
    /// nil means the selection doesn't agree — the field shows "Mixed" and typing
    /// a number brings every selected layer to it.
    let value: CGFloat?
    var suffix: String = ""
    let onCommit: (CGFloat) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    init(label: String, value: CGFloat?, suffix: String = "",
         onCommit: @escaping (CGFloat) -> Void) {
        self.label = label
        self.value = value
        self.suffix = suffix
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: FieldMetrics.labelWidth, alignment: .leading)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            TextField(value == nil ? "Mixed" : "", text: $text)
                // Named so UI tests can read a value back — "did the angle change?"
                // is otherwise unanswerable from outside the app.
                .accessibilityIdentifier("field-\(label)")
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onChange(of: value) { _, _ in if !focused { text = format(value) } }
                .onAppear { text = format(value) }
                // Arrow keys nudge the number the way they nudge a layer: 1 at a
                // time, 10 with shift. Committed immediately, so the canvas moves
                // with each press instead of waiting for Return.
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
                    let direction: CGFloat = press.key == .upArrow ? 1 : -1
                    let typed = Double(text.replacingOccurrences(of: suffix, with: "")
                        .trimmingCharacters(in: .whitespaces))
                    let base: CGFloat = typed.map { CGFloat($0) } ?? value ?? 0
                    let v = base + direction * step
                    text = format(v)
                    onCommit(v)
                    return .handled
                }
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

    private func format(_ v: CGFloat?) -> String {
        guard let v else { return "" }            // mixed: empty, the prompt says why
        return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
