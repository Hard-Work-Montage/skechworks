import AccompliceCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: DocumentStore
    @State private var zoomToken = 0

    var body: some View {
        NavigationSplitView {
            pageList
        } content: {
            canvas
        } detail: {
            inspector
        }
        .navigationTitle(store.url?.lastPathComponent ?? "Accomplice")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { store.openPanel() } label: { Label("Open", systemImage: "folder") }
                    .help("Open an .acmplc.png or .sketch file")
            }
            ToolbarItem {
                Button { zoomToken += 1 } label: { Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help("Fit page to window")
                    .disabled(store.page == nil)
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

    // MARK: - Pages

    private var pageList: some View {
        VStack(spacing: 0) {
            if let src = store.source {
                List(selection: Binding(
                    get: { store.pageIndex },
                    set: { store.pageIndex = $0 ?? 0; store.selectedLayerID = nil }
                )) {
                    Section("Pages") {
                        // Names and layer counts come from document.json, so the whole
                        // sidebar is available before a single page has been parsed.
                        ForEach(Array(src.pages.enumerated()), id: \.offset) { i, p in
                            HStack {
                                Text(p.name).lineLimit(1)
                                Spacer()
                                Text("\(p.layerCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .tag(i)
                        }
                    }
                }
            } else {
                emptyState
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.on.circle").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("Drop a document here").font(.headline)
            Text(".acmplc.png or .sketch")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open…") { store.openPanel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            CanvasRepresentable(page: store.page, images: store.images,
                                selectedID: $store.selectedLayerID, zoomToken: zoomToken)
            if store.isLoading || store.isPageLoading {
                ProgressView().controlSize(.large).padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .navigationSplitViewColumnWidth(min: 320, ideal: 760)
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

    // MARK: - Layers

    private var inspector: some View {
        Group {
            if let page = store.page {
                List(page.layers.map(LayerNode.init), children: \.children,
                     selection: $store.selectedLayerID) { node in
                    HStack(spacing: 6) {
                        Image(systemName: node.systemImage)
                            .foregroundStyle(.secondary).frame(width: 14)
                        Text(node.name).lineLimit(1)
                            .foregroundStyle(node.isVisible ? .primary : .tertiary)
                    }
                    .tag(node.id)
                }
            } else {
                Text("No document").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 420)
    }
}
