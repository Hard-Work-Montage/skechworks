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
    @State private var expanded: Set<String> = []

    private struct LayerRow: Identifiable {
        let node: LayerNode
        let depth: Int
        var id: String { node.id }
    }

    private func rows(_ nodes: [LayerNode], depth: Int = 0) -> [LayerRow] {
        var out: [LayerRow] = []
        for n in nodes {
            out.append(LayerRow(node: n, depth: depth))
            if let kids = n.children, expanded.contains(n.id) {
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
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                    Divider()
                    Button("Rectangle") { store.insertRectangle() }
                        .keyboardShortcut("r", modifiers: [])
                    Button("Oval") { store.insertOval() }
                        .keyboardShortcut("o", modifiers: [])
                    Button("Vector") { store.tool = .pen }
                        .keyboardShortcut("p", modifiers: [])
                    Divider()
                    Button("Text") { store.insertText() }
                        .keyboardShortcut("t", modifiers: [])
                    Button("Image…") { store.insertImage() }
                } label: {
                    Label("Insert", systemImage: "plus")
                }
                .menuIndicator(.hidden)
                .help("Insert artboard, shape, vector, text or image")
                .disabled(store.source == nil)
            }
            ToolbarItem {
                Picker("Tool", selection: $store.tool) {
                    ForEach(DocumentStore.Tool.allCases, id: \.self) { t in
                        Label(t.title, systemImage: t.symbol).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("Select (V) · Pen (P) · Bend (B)")
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
                    List(rows(page.layers.map(LayerNode.init)), selection: $store.selection) { row in
                        layerRow(row)
                            .tag(row.node.id)
                            .id(row.node.id)
                    }
                    .listStyle(.sidebar)
                    // Only fires when the list itself has focus, so it can't fight a
                    // text field in the inspector for the delete key.
                    .onDeleteCommand { store.deleteSelection() }
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
                .foregroundStyle(.secondary).frame(width: 14)
            Text(row.node.name).lineLimit(1)
                .foregroundStyle(row.node.isVisible ? .primary : .tertiary)
        }
        .padding(.leading, CGFloat(row.depth) * 12)
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
                                revision: store.revision, tool: store.tool,
                                pageToken: store.pageToken)
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
