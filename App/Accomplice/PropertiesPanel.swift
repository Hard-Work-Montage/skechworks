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
                        if !layer.style.fills.isEmpty { Divider(); fills(layer) }
                        if !layer.style.borders.isEmpty { Divider(); borders(layer) }
                        if case .bitmap = layer.kind { Divider(); eraser(layer) }
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
            } else {
                VStack(spacing: 6) {
                    Image(systemName: selectionCount > 1 ? "square.on.square" : "sidebar.right")
                        .font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(selectionCount > 1 ? "\(selectionCount) layers selected" : "No selection")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("selection-summary")
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
