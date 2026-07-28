import AccompliceCore
import SwiftUI
import UniformTypeIdentifiers

// Sketch/Figma layout: navigation on the left (pages over layers, resizable between
// them), canvas in the middle, properties on the right. Getting this in place before
// editing lands means the inspector has somewhere to grow into.
struct ContentView: View {
    @EnvironmentObject var store: DocumentStore
    @State private var showCommandBar = false

    /// Which groups are open in the layer list.
    ///
    /// SwiftUI's `List(children:)` owns its own disclosure state and won't let us open
    /// a group programmatically — so the tree is flattened by hand. That's what makes
    /// "select a shape on the canvas and its layer is revealed and highlighted"
    /// possible, which is the entire point.
    @State private var renamingID: String?
    @State private var renameText = ""
    @State private var expanded: Set<String> = []
    @StateObject private var drag = LayerDragState()
    private let layerRowHeight: CGFloat = 24

    private struct LayerRow: Identifiable {
        let node: LayerNode
        let depth: Int
        var id: String { node.id }
    }

    private func rows(_ nodes: [LayerNode], depth: Int = 0) -> [LayerRow] {
        var out: [LayerRow] = []
        for n in nodes {
            out.append(LayerRow(node: n, depth: depth))
            // Under test everything is open, so a test never depends on having
            // clicked its way down the tree first.
            if let kids = n.children, expanded.contains(n.id) || TestFixture.requested {
                out.append(contentsOf: rows(kids, depth: depth + 1))
            }
        }
        return out
    }

    /// Opens every ancestor of the selection so the row actually exists to scroll to.
    private func reveal(_ ids: Set<String>) {
        guard let page = store.page else { return }
        for id in ids { expanded.formUnion(page.ancestors(of: id)) }
    }

    var body: some View {
        NavigationSplitView {
            leftRail
        } content: {
            canvas
        } detail: {
            rightRail
        }
        // "Untitled" rather than the app name: with several new documents open, every
        // tab reading "Accomplice" tells you nothing.
        .navigationTitle(store.displayName)
        .navigationSubtitle(store.isDirty ? "Edited" : "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // The logo sits left of the insert menu, the way Sketch does it.
                if let icon = AppIconTheme.current.thumbnail(points: 22) {
                    Image(nsImage: icon)
                        .resizable().interpolation(.high)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .padding(.leading, 14)   // clear of the sidebar divider
                }
            }
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("Artboard") { store.insertArtboard() }
                        .shortcut("insertArtboard")
                    Divider()
                    Button("Rectangle") { store.insertRectangle() }
                        .shortcut("insertRect")
                    Button("Oval") { store.insertOval() }
                        .shortcut("insertOval")
                    Button("Vector") { store.tool = .pen }
                        .shortcut("vector")
                    Divider()
                    Button("Text") { store.insertText() }
                        .shortcut("insertText")
                    Button("Image…") { store.insertImage() }
                } label: {
                    Label("Insert", systemImage: "plus")
                }
                .menuIndicator(.hidden)
                .help("Insert artboard, shape, vector, text or image")
                .disabled(store.source == nil)
            }
            // No tool picker. Insert ▸ Vector (P) starts drawing and Escape stops,
            // so a persistent three-way switch was one redundant control and one that
            // stood in for a point property.
            ToolbarItem {
                if store.tool == .pen {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil.tip").foregroundStyle(.tint)
                        Text("Vector — Return to finish, Esc to cancel")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.tint.opacity(0.12), in: Capsule())
                }
            }
            ToolbarItem {
                Button { store.zoom(.fit) } label: { Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help("Fit page to window")
                    .disabled(store.page == nil)
            }
            ToolbarItem {
                Button { store.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .help("Undo").disabled(!store.canUndo)
            }
            ToolbarItem {
                Button { store.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .help("Save").disabled(!store.isDirty)
            }
            ToolbarItem {
                Button { showCommandBar.toggle() } label: {
                    Label("Ask", systemImage: "sparkles")
                }
                .help("Ask (⌘K)")
            }
            ToolbarItem {
                Menu {
                    Button("Export This Page as SVG…") { store.exportCurrentPage() }
                    Button("Export All Pages as SVG…") { store.exportAllPages() }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(store.source == nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCommandBar)) { _ in
            showCommandBar = true
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            // Documents open; images (and anything else decodable) get placed. Routing
            // everything through open() meant dropping a photo destroyed the document.
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in store.acceptDropped(url) } }
            }
            return true
        }
    }

    /// Properties over chat, split vertically — the same shape as pages over layers on
    /// the left. A separate inspector column made four panels, which is one more than
    /// any of them deserved.
    private var rightRail: some View {
        Group {
            if showCommandBar {
                VSplitView {
                    properties
                        .frame(minHeight: 140, idealHeight: 300)
                    VStack(alignment: .leading, spacing: 0) {
                        railHeader("Chat", count: nil)
                        ChatPanel().environmentObject(store)
                    }
                    .frame(minHeight: 200)
                }
            } else {
                properties
            }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 520)
    }

    private var properties: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader("Properties", count: nil)
            PropertiesPanel(layer: selectedLayer, pageName: store.page?.name,
                            selectionCount: selectionCount)
        }
    }

    private var selectedLayer: Layer? {
        guard let id = store.selectedLayerID, let page = store.page else { return nil }
        return LayerLookup.find(id, in: page.layers)
    }

    private var selectionCount: Int { store.selection.count }

    // MARK: - Left rail

    private var leftRail: some View {
        Group {
            if store.source != nil {
                // VSplitView gives the draggable divider; both halves keep whatever
                // proportion you leave them at.
                VSplitView {
                    pageList
                        .frame(minHeight: 120, idealHeight: 240)
                    layerList
                        .frame(minHeight: 120)
                }
            } else {
                emptyState
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
    }

    private var pageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader("Pages", count: store.source?.pageCount)
            List(selection: Binding(
                get: { store.pageIndex },
                set: { store.pageIndex = $0 ?? 0; store.selection = [] }
            )) {
                // Names and layer counts come from document.json, so the whole sidebar
                // is populated before any page geometry has been parsed.
                ForEach(Array((store.source?.pages ?? []).enumerated()), id: \.offset) { i, p in
                    HStack {
                        Text(p.name).lineLimit(1)
                        Spacer()
                        Text("\(p.layerCount)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .tag(i)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var layerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader("Layers", count: store.page?.layers.count)
            if let page = store.page {
                ScrollViewReader { proxy in
                    // Plain rows rather than List selection: attaching .onDrag to a
                    // selectable row stops the tap registering, so clicking a layer
                    // highlighted nothing. Selection is handled here instead, which
                    // also lets the highlight stay strong when focus is on the canvas —
                    // the layer list is how you keep track of what you're editing.
                    List(rows(page.layers.map(LayerNode.init))) { row in
                        layerRow(row)
                            .listRowBackground(
                                store.selection.contains(row.node.id)
                                    ? AnyView(RoundedRectangle(cornerRadius: 5).fill(.tint))
                                    : AnyView(Color.clear))
                            .id(row.node.id)
                    }
                    .listStyle(.sidebar)
                    .onDrop(of: [.text], delegate: LayerRootDropDelegate(state: drag, store: store))
                    // Only fires when the list itself has focus, so it can't fight a
                    // text field in the inspector for the delete key.
                    .onDeleteCommand { store.deleteSelection() }
                    .alert("Rename Layer", isPresented: Binding(
                        get: { renamingID != nil },
                        set: { if !$0 { renamingID = nil } })) {
                        TextField("Name", text: $renameText)
                        Button("Rename") {
                            if let id = renamingID { store.rename(id, to: renameText) }
                            renamingID = nil
                        }
                        Button("Cancel", role: .cancel) { renamingID = nil }
                    }
                    .onChange(of: store.selection) { _, new in
                        guard let first = new.first else { return }
                        reveal(new)
                        // After the rows rebuild, bring it into view.
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(first, anchor: .center) }
                        }
                    }
                }
            } else {
                Color.clear
            }
        }
    }

    private func layerRow(_ row: LayerRow) -> some View {
        HStack(spacing: 5) {
            if row.node.children != nil {
                Button {
                    if expanded.contains(row.node.id) { expanded.remove(row.node.id) }
                    else { expanded.insert(row.node.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(expanded.contains(row.node.id) ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 10)
            }
            Image(systemName: row.node.systemImage)
                .foregroundStyle(rowForeground(row)).frame(width: 14)
            Text(row.node.name).lineLimit(1)
                .foregroundStyle(rowForeground(row))
        }
        .padding(.leading, CGFloat(row.depth) * 12)
        .frame(height: layerRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One element per row, named for the UI tests. Without combining, the
        // identifier lands on the chevron, the icon and the label separately and a
        // query for the row matches three things.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("layer-\(row.node.name)")
        .contentShape(Rectangle())          // the whole row is a target, not just the text
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
                // Shift or command adds to the selection, as everywhere else.
                if store.selection.contains(row.node.id) { store.selection.remove(row.node.id) }
                else { store.selection.insert(row.node.id) }
            } else {
                store.selection = [row.node.id]
            }
        }
        .overlay(alignment: .top) {
            if drag.spot == .above(row.node.id) { dropLine(row.depth) }
        }
        .overlay(alignment: .bottom) {
            if drag.spot == .below(row.node.id) { dropLine(row.depth) }
        }
        .background {
            // Highlight the container itself, so "into" reads differently from "between".
            if drag.spot == .inside(row.node.id) {
                RoundedRectangle(cornerRadius: 4).fill(.tint.opacity(0.25))
            }
        }
        .opacity(drag.dragging.contains(row.node.id) ? 0.4 : 1)
        .onDrag {
            // Dragging an unselected row acts on that row, matching the context menu.
            if !store.selection.contains(row.node.id) { store.selection = [row.node.id] }
            drag.dragging = store.selection
            return NSItemProvider(object: row.node.id as NSString)
        }
        .onDrop(of: [.text], delegate: LayerDropDelegate(
            rowID: row.node.id,
            isContainer: store.page?.layer(row.node.id)?.isContainer ?? false,
            rowHeight: layerRowHeight,
            state: drag,
            store: store,
            expanded: expanded,
            expand: { expanded.insert($0) }))
        .contextMenu { layerMenu(row) }
    }

    private func rowForeground(_ row: LayerRow) -> SwiftUI.Color {
        if store.selection.contains(row.node.id) { return .white }
        return row.node.isVisible ? .primary : SwiftUI.Color.secondary.opacity(0.6)
    }

    private func dropLine(_ depth: Int) -> some View {
        Rectangle().fill(.tint).frame(height: 2)
            .padding(.leading, CGFloat(depth) * 12)
    }

    /// Sketch's layer menu, minus what this doesn't have.
    ///
    /// Right-clicking selects first: acting on a hidden selection because you
    /// right-clicked something else is how you delete the wrong layer.
    @ViewBuilder
    private func layerMenu(_ row: LayerRow) -> some View {
        let id = row.node.id
        let layer = store.page?.layer(id)

        Group {
            Button("Rename…") {
                select(id)
                renamingID = id
                renameText = layer?.name ?? ""
            }
            Divider()
            Button("Cut") { select(id); store.cutSelection() }
            Button("Copy") { select(id); store.copySelection() }
            Button("Paste") { select(id); store.paste() }
            Button("Duplicate") { select(id); store.duplicateSelection() }
            Divider()
            Button("Group") { select(id); store.groupSelection() }
            Button("Ungroup") { select(id); store.ungroupSelection() }
                .disabled(row.node.children == nil)
        }
        Group {
            Divider()
            Menu("Move") {
                Button("Bring to Front") { select(id); store.bringToFront() }
                Button("Bring Forward") { select(id); store.bringForward() }
                Button("Send Backward") { select(id); store.sendBackward() }
                Button("Send to Back") { select(id); store.sendToBack() }
            }
            Divider()
            Button(layer?.hasClippingMask == true ? "Remove Mask" : "Use as Mask") {
                select(id); store.toggleMask()
            }
            Button(layer?.breaksMaskChain == true ? "Honour Mask" : "Ignore Mask") {
                select(id); store.toggleIgnoreMask()
            }
            Divider()
            Button(layer?.isVisible == false ? "Show Layer" : "Hide Layer") {
                select(id); store.toggleLockOrHide(hide: true)
            }
            Divider()
            Button("Delete", role: .destructive) { select(id); store.deleteSelection() }
        }
    }

    /// Right-clicking a layer that isn't selected acts on it, not on the old selection.
    private func select(_ id: String) {
        if !store.selection.contains(id) { store.selection = [id] }
    }

    @ViewBuilder
    private func railHeader(_ title: String, count: Int?) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).tracking(0.6)
            Spacer()
            if let count {
                Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.on.circle").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("Drop a document here").font(.headline)
            Text(".acmplc.png or .sketch").font(.caption).foregroundStyle(.secondary)
            Button("Open…") { store.openPanel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            CanvasRepresentable(page: store.page, images: store.images,
                                selection: $store.selection, zoom: store.zoomRequest,
                                pointMode: store.pointModeRequest,
                                revision: store.revision, tool: store.tool,
                                pageToken: store.pageToken)
            Color.clear.accessibilityIdentifier("canvas").allowsHitTesting(false)
            if store.isLoading || store.isPageLoading {
                ProgressView().controlSize(.large).padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .navigationSplitViewColumnWidth(min: 320, ideal: 720)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Text(store.status).font(.caption).foregroundStyle(.secondary)
                if !store.fontWarnings.isEmpty {
                    Divider().frame(height: 12)
                    Label("\(store.fontWarnings.count) font substituted", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .help(store.fontWarnings.map { "\($0.0) → \($0.1)" }.joined(separator: "\n"))
                }
                Spacer()
                if let b = store.page?.contentBounds() {
                    Text("\(Int(b.width)) × \(Int(b.height))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
    }
}
