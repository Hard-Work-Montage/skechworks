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


    /// Sketch's row: six align icons, then the two flips. Lives above the fields
    /// because it acts on the selection as a whole, not on one number.
    private func alignRow(alignEnabled: Bool) -> some View {
        HStack(spacing: 1) {
            Group {
                alignButton("align.horizontal.left", .left, "Left")
                alignButton("align.horizontal.center", .horizontalCentre, "Center")
                alignButton("align.horizontal.right", .right, "Right")
                Divider().frame(height: 14).padding(.horizontal, 3)
                alignButton("align.vertical.top", .top, "Top")
                alignButton("align.vertical.center", .verticalMiddle, "Middle")
                alignButton("align.vertical.bottom", .bottom, "Bottom")
            }
            // A lone layer aligns to its artboard; a loose one has nothing to
            // align to, so the buttons sit disabled rather than vanishing.
            .disabled(!alignEnabled)
            .opacity(alignEnabled ? 1 : 0.35)
            Spacer(minLength: 0)
            iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip Horizontal") {
                store.flipSelection(horizontal: true)
            }
            iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip Vertical") {
                store.flipSelection(horizontal: false)
            }
        }
        .foregroundStyle(.secondary)
    }

    private func alignButton(_ symbol: String, _ edge: AlignEdge, _ name: String) -> some View {
        iconButton(symbol, "Align \(name)") { store.align(edge, name) }
    }

    /// The W/H padlock. Locked keeps the aspect ratio exact through typed sizes
    /// and canvas drags; shift inverts the mode mid-drag.
    @ViewBuilder
    private func ratioLock(_ l: Layer) -> some View {
        // Type has no aspect ratio worth keeping: a text box is resized to change
        // where the copy wraps, never to stretch the letters.
        if case .text = l.kind {
            EmptyView()
        } else {
        iconButton(l.constrainProportions ? "lock.fill" : "lock.open",
                   l.constrainProportions ? "Unlock aspect ratio" : "Lock aspect ratio") {
            store.edit(l.id, actionName: l.constrainProportions ? "Unlock Ratio" : "Lock Ratio") {
                $0.constrainProportions.toggle()
            }
        }
        .foregroundStyle(l.constrainProportions ? Color.accentColor : Color.secondary)
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
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
            alignRow(alignEnabled: true)
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Position & Size")
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    GridRow {
                        multiEditable("X", common { $0.frame.minX }) { l, v in l.frame.origin.x = v }
                        multiEditable("Y", common { $0.frame.minY }) { l, v in l.frame.origin.y = v }
                    }
                    GridRow {
                        multiEditable("W", common { $0.frame.width }) { l, v in
                            let w = max(1, v)
                            let h = l.constrainProportions
                                ? l.frame.height * (w / max(l.frame.width, 0.001)) : l.frame.height
                            l.resize(to: CGSize(width: w, height: h))
                        }
                        multiEditable("H", common { $0.frame.height }) { l, v in
                            let h = max(1, v)
                            let w = l.constrainProportions
                                ? l.frame.width * (h / max(l.frame.height, 0.001)) : l.frame.width
                            l.resize(to: CGSize(width: w, height: h))
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
        // A masked group paints less than its frame says — describe the visible
        // region, and map edits back through it (unmasked layers keep exact frame
        // semantics, so a rotated layer's W/H don't turn into its rotated bbox).
        let masked = l.containsClippingMask
        let vb = masked ? Compose.visibleBounds(of: l) : l.frame
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Position & Size")
            alignRow(alignEnabled: store.page.map { page in
                page.ancestors(of: l.id).contains { page.layer($0)?.isArtboard == true }
            } ?? false)
            // Two even columns throughout, so every field lines up regardless of how
            // long its label is. A fixed label column is what stops "Opacity" wrapping
            // onto a second line and shoving its field out of alignment.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    editable("X", vb.minX, l) { layer, v in layer.frame.origin.x += v - vb.minX }
                    editable("Y", vb.minY, l) { layer, v in layer.frame.origin.y += v - vb.minY }
                }
                GridRow {
                    editable("W", vb.width, l) { layer, v in
                        let w = masked ? layer.frame.width * (max(1, v) / max(vb.width, 0.001))
                                       : max(1, v)
                        let h = layer.constrainProportions
                            ? layer.frame.height * (w / max(layer.frame.width, 0.001))
                            : layer.frame.height
                        layer.resize(to: CGSize(width: w, height: h))
                    }
                    editable("H", vb.height, l) { layer, v in
                        let h = masked ? layer.frame.height * (max(1, v) / max(vb.height, 0.001))
                                       : max(1, v)
                        let w = layer.constrainProportions
                            ? layer.frame.width * (h / max(layer.frame.height, 0.001))
                            : layer.frame.width
                        layer.resize(to: CGSize(width: w, height: h))
                    }
                    ratioLock(l)
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
                    // Scoped to whatever is picked. With points selected in
                    // point-edit mode this sets those corners; otherwise it sets
                    // the shape, which is how it has always behaved.
                    NumberField(label: "Radius",
                                value: store.cornerRadiusShown(for: l, points: store.selectedPoints)) { v in
                        store.setCornerRadius(v, on: l.id, points: store.selectedPoints)
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
                    .disabled(l.cornerRadius <= 0 && !l.cornerRadii.contains { $0 > 0 })
                }
            }
            if !store.selectedPoints.isEmpty {
                let n = store.selectedPoints.count
                Text("Setting \(n) selected corner\(n == 1 ? "" : "s"). Click off the points to set the whole shape.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("corner-scope")
            } else if l.hasMixedCorners {
                Text("Corners differ. Typing here sets them all to one value.")
                    .font(.caption).foregroundStyle(.secondary)
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

    /// Border width and anything else that used to roll its own field: one
    /// component, so the arrow keys behave the same everywhere.
    private func numberField(_ label: String, _ value: CGFloat,
                             _ set: @escaping (CGFloat) -> Void) -> some View {
        NumberField(label: label, value: value) { set($0) }
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
                    store.editShadow(l.id, at: i, actionName: "Change Shadow Color",
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
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Text")
            // No copy of the words here. Double-clicking types them where they
            // sit, in the face and colour they are actually in, which is a
            // better editor than a grey box in a side panel could ever be.
            // Both menus take a whole row. Half a row truncates a family to
            // "Fi…" and a style to "Se…", and a menu you have to open to read
            // is not telling you anything. The numbers pair up underneath, and
            // Line rides alongside the alignment buttons, which are the only
            // other thing here of a fixed width.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow { fontPicker(t, layer).gridCellColumns(2) }
                GridRow { facePicker(t, layer).gridCellColumns(2) }
                GridRow {
                    editableText("Size", t.fontSize, layer) { run, v in
                        run.fontSize = max(1, v)
                    }
                    editableText("Kern", t.kerning, layer) { run, v in run.kerning = v }
                }
                GridRow {
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
                    editableText("Line", t.lineHeight, layer) { run, v in
                        run.lineHeight = max(0, v)
                    }
                }
            }
            curve(t, layer)
        }
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
        let family = Faces.family(of: t.fontName)
        return HStack(spacing: 5) {
            Text("Font")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: FieldMetrics.labelWidth, alignment: .leading)
            FontPopUp(choices: Faces.families(including: family), current: family) { picked in
                // Keep the weight when the family changes. Going from Helvetica
                // Bold to Futura and landing on Futura Regular loses something
                // nobody asked to lose.
                let want = Faces.face(of: t.fontName)
                guard let name = Faces.member(matching: want, in: picked) else { return }
                store.editText(l.id, "Change Font") { $0.fontName = name }
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("font-picker")
        }
    }

    /// The cuts this family ships. Most have Regular, Italic, Bold, Bold Italic;
    /// a display face may have exactly one, and it still gets a menu with that
    /// one in it rather than nothing — the row shouldn't appear and disappear.
    private func facePicker(_ t: TextRun, _ l: Layer) -> some View {
        let family = Faces.family(of: t.fontName)
        let faces = Faces.members(of: family, fallback: t.fontName)
        return HStack(spacing: 5) {
            Text("Style")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: FieldMetrics.labelWidth, alignment: .leading)
            FontPopUp(choices: faces, current: t.fontName) { name in
                store.editText(l.id, "Change Style") { $0.fontName = name }
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("font-face-picker")
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
                    Button("Reset color") {
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
    @State private var stepMonitor: Any?

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
                .onChange(of: focused) { _, isFocused in
                    if isFocused { startStepping() } else { stopStepping(); commit() }
                }
                .onDisappear { stopStepping() }
                .onChange(of: value) { _, _ in if !focused { text = format(value) } }
                .onAppear { text = format(value) }
                // Arrow keys nudge the number the way they nudge a layer: 1 at a
                // time, 10 with shift, committed immediately so the canvas moves
                // with each press instead of waiting for Return.
                //
                // Via an event monitor rather than .onKeyPress, which never fires
                // here: the focused text field swallows the arrows to move its own
                // caret, so the modifier below it is never consulted. This looked
                // right in the source and did nothing for weeks.
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

    /// Up and down step the value while this field has focus: 1, or 10 with shift.
    private func startStepping() {
        guard stepMonitor == nil else { return }
        stepMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // NSEvent isn't Sendable, so only the verdict crosses back.
            let handled = MainActor.assumeIsolated { () -> Bool in
                // Escape hands the field back. Without it the only way out of a
                // number you have half-typed is to click somewhere else, and the
                // key that means "stop what you are doing" everywhere else in the
                // app did nothing here.
                if focused, event.keyCode == 53 {
                    commit()
                    focused = false
                    return true
                }
                guard focused, event.keyCode == 125 || event.keyCode == 126,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty
                else { return false }
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                let direction: CGFloat = event.keyCode == 126 ? 1 : -1
                let typed = Double(text.replacingOccurrences(of: suffix, with: "")
                    .trimmingCharacters(in: .whitespaces))
                let base: CGFloat = typed.map { CGFloat($0) } ?? value ?? 0
                let v = base + direction * step
                text = format(v)
                onCommit(v)
                return true
            }
            return handled ? nil : event
        }
    }

    private func stopStepping() {
        if let m = stepMonitor { NSEvent.removeMonitor(m) }
        stepMonitor = nil
    }

    private func format(_ v: CGFloat?) -> String {
        guard let v else { return "" }            // mixed: empty, the prompt says why
        return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

/// The font menu with every family previewing itself — the way every design app
/// since Fireworks has shown fonts. An NSPopUpButton underneath, because
/// SwiftUI's Menu ignores per-item fonts on macOS; symbol fonts whose names
/// would render as dingbats fall back to the system face.
/// Font families and the cuts inside them.
///
/// A text run stores one name and the canvas draws that name, which is right —
/// but it means "Helvetica" and "Helvetica Bold" are two unrelated strings as
/// far as the document is concerned. The panel has to put them back together:
/// which family is this, which cut of it, and what else does the family have.
///
/// Family names are not always usable as font names. Eveleth ships one member
/// called "Eveleth Clean Regular" and nothing named "Eveleth" at all, so a
/// picker that wrote the family straight into the run named a font that does
/// not exist.
@MainActor
enum Faces {
    struct Choice: Equatable {
        var value: String
        var label: String
        /// The name to draw the label in, so a menu of fonts looks like fonts.
        var preview: String?
    }

    /// The family a font name belongs to, or the name itself when the machine
    /// hasn't got it — a document naming a font you lack should still say so.
    static func family(of name: String) -> String {
        NSFont(name: name, size: 12)?.familyName ?? name
    }

    /// What this cut is called: "Bold", "Clean Regular", and so on.
    static func face(of name: String) -> String {
        members(of: family(of: name), fallback: name)
            .first { $0.value == name }?.label ?? "Regular"
    }

    /// Three hundred families, built once. The properties panel re-renders on
    /// every selection and every drag, and asking AppKit for the whole list and
    /// mapping it each time made a menu nobody opened the most expensive thing
    /// on screen.
    private static let installed: [Choice] = NSFontManager.shared.availableFontFamilies
        .map { Choice(value: $0, label: $0, preview: $0) }

    static func families(including current: String) -> [Choice] {
        // A missing font still has to be selectable, or the popup shows the
        // first family in the list and the panel lies about the document.
        guard !installed.contains(where: { $0.value == current }) else { return installed }
        return (installed + [Choice(value: current, label: current, preview: nil)])
            .sorted { $0.label < $1.label }
    }

    /// Likewise per family: the face list is asked for on every render of the
    /// row, and it only changes when a font is installed.
    private static var cachedMembers: [String: [Choice]] = [:]

    /// availableMembers gives [postScriptName, faceName, weight, traits] per cut.
    static func members(of family: String, fallback: String) -> [Choice] {
        if let hit = cachedMembers[family] {
            return hit.isEmpty ? [Choice(value: fallback, label: "Regular", preview: nil)] : hit
        }
        let raw = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        let choices = raw.compactMap { m -> Choice? in
            guard m.count >= 2, let name = m[0] as? String, let label = m[1] as? String
            else { return nil }
            return Choice(value: name, label: label, preview: name)
        }
        cachedMembers[family] = choices
        return choices.isEmpty ? [Choice(value: fallback, label: "Regular", preview: nil)] : choices
    }

    /// The cut of `family` closest to one called `face`.
    ///
    /// By name first, because "Bold" means the same thing in both families. When
    /// there is no such cut, whatever the family calls plain, and failing that
    /// its first — never nothing, since the family was just chosen and has to
    /// end up selected.
    static func member(matching face: String, in family: String) -> String? {
        let all = members(of: family, fallback: family)
        if let exact = all.first(where: { $0.label.caseInsensitiveCompare(face) == .orderedSame }) {
            return exact.value
        }
        if let plain = all.first(where: { $0.label.caseInsensitiveCompare("Regular") == .orderedSame }) {
            return plain.value
        }
        return all.first?.value
    }
}

/// A popup of fonts, each item shown in the font it names.
private struct FontPopUp: NSViewRepresentable {
    var choices: [Faces.Choice]
    var current: String
    var onPick: (String) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = CompressiblePopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 12)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onPick = onPick
        // Rebuilt only when the list really changed. Choosing a family changes
        // the face list under it, and rebuilding on every pass would close the
        // menu out from under a click.
        if context.coordinator.choices.count != choices.count
            || context.coordinator.choices.first != choices.first {
            context.coordinator.choices = choices
            let menu = NSMenu()
            for c in choices {
                let item = NSMenuItem(title: c.label, action: nil, keyEquivalent: "")
                item.representedObject = c.value
                if let preview = c.preview, let f = NSFont(name: preview, size: 13) {
                    item.attributedTitle = NSAttributedString(string: c.label, attributes: [.font: f])
                }
                menu.addItem(item)
            }
            button.menu = menu
        }
        let wanted = button.menu?.items.firstIndex { $0.representedObject as? String == current }
        if let wanted {
            button.selectItem(at: wanted)
        } else if let first = choices.first {
            // Nothing matched, which means the run names a cut this family
            // doesn't have. Show the family's own first rather than whatever
            // item happens to be selected.
            button.selectItem(withTitle: first.label)
        }
    }

    /// SwiftUI sizes a representable from the view's intrinsic size, and a
    /// popup's intrinsic width is its WIDEST MENU ITEM. With every family
    /// previewing itself one of those items is a billboard, and the inspector
    /// column stretched to fit it. Take the proposed width instead.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: nsView.fittingSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject {
        var onPick: (String) -> Void
        var choices: [Faces.Choice] = []
        init(onPick: @escaping (String) -> Void) { self.onPick = onPick }
        @objc func picked(_ sender: NSPopUpButton) {
            if let value = sender.selectedItem?.representedObject as? String { onPick(value) }
        }
    }
}

/// A popup that doesn't insist on being as wide as its widest menu item — the
/// belt to `sizeThatFits`'s braces, since AppKit consults this directly too.
private final class CompressiblePopUpButton: NSPopUpButton {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }
}
