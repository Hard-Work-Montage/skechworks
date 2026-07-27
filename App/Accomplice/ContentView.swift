import AccompliceCore
import SwiftUI
import UniformTypeIdentifiers

// Sketch/Figma layout: navigation on the left (pages over layers, resizable between
// them), canvas in the middle, properties on the right. Getting this in place before
// editing lands means the inspector has somewhere to grow into.
struct ContentView: View {
    @EnvironmentObject var store: DocumentStore
    @State private var zoomToken = 0

    var body: some View {
        NavigationSplitView {
            leftRail
        } content: {
            canvas
        } detail: {
            PropertiesPanel(layer: selectedLayer, pageName: store.page?.name,
                            selectionCount: selectionCount)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        }
        .navigationTitle(store.url?.lastPathComponent ?? "Accomplice")
        .navigationSubtitle(store.isDirty ? "Edited" : "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { store.openPanel() } label: { Label("Open", systemImage: "folder") }
                    .help("Open an .acmplc.png or .sketch file")
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
                Button { zoomToken += 1 } label: { Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right") }
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
                Menu {
                    Button("Export This Page as SVG…") { store.exportCurrentPage() }
                    Button("Export All Pages as SVG…") { store.exportAllPages() }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(store.source == nil)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in store.open(url) } }
            }
            return true
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
                List(page.layers.map(LayerNode.init), children: \.children,
                     selection: $store.selection) { node in
                    HStack(spacing: 6) {
                        Image(systemName: node.systemImage)
                            .foregroundStyle(.secondary).frame(width: 14)
                        Text(node.name).lineLimit(1)
                            .foregroundStyle(node.isVisible ? .primary : .tertiary)
                    }
                    .tag(node.id)
                }
                .listStyle(.sidebar)
            } else {
                Color.clear
            }
        }
    }

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
                                selection: $store.selection, zoomToken: zoomToken,
                                revision: store.revision, tool: store.tool)
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
