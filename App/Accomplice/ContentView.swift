import AccompliceCore
import SwiftUI
import UniformTypeIdentifiers

// Sketch/Figma layout: navigation on the left (pages over layers, resizable between
// them), canvas in the middle, properties on the right. Getting this in place before
// editing lands means the inspector has somewhere to grow into.
struct ContentView: View {
    @EnvironmentObject var store: DocumentStore
    /// Chat is open by default, and stays however you last left it — the same as the
    /// sidebar. It was hidden behind a toolbar button, which is a poor place for
    /// something you'd otherwise forget is there.
    @AppStorage("showChat") private var showCommandBar = true

    /// Which groups are open in the layer list.
    ///
    /// SwiftUI's `List(children:)` owns its own disclosure state and won't let us open
    /// a group programmatically — so the tree is flattened by hand. That's what makes
    /// "select a shape on the canvas and its layer is revealed and highlighted"
    /// possible, which is the entire point.
    /// The split view used to provide the collapse button; with plain columns it's
    /// ours to keep.
    @State private var renamingPage: Int?
    @State private var renameText = ""
    @State private var expanded: Set<String> = []


    var body: some View {
        // Three plain columns rather than a NavigationSplitView.
        //
        // The split view gives its first column macOS's sidebar treatment — inset,
        // translucent, rounded — while the detail column stays flush and opaque. Side
        // by side in one window the two read as different materials, and the window
        // NavigationSplitView, which is what Apple asks for: on macOS 26 the first
        // column becomes a Liquid Glass sidebar that floats above the content, and you
        // get it by using the standard structure rather than by building one.
        //
        // Adam had this right. The rounded sidebar was never the mistake — pairing it
        // with a full-width solid toolbar was, because that's the older idiom and the
        // two collide where they meet. Apple's own guidance for the new design is to
        // remove custom backgrounds from behind toolbars, which is the one line below.
        //
        // I did try hand-rolling three columns to get the inset. It doesn't work and
        // the reason is worth writing down: an NSView with no intrinsic content size
        // maps to 0…0…∞ in SwiftUI, so both rails — NSScrollViews, both of them — take
        // whatever size is proposed, and in a plain HStack that resolves to zero. The
        // left rail vanished entirely. NavigationSplitView assigns column widths
        // itself, which is exactly the part that was missing.
        NavigationSplitView {
            leftRail
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } content: {
            canvas
                .navigationSplitViewColumnWidth(min: 320, ideal: 720)
        } detail: {
            rightRail
                .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 520)
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
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
                    Button("Artboard from Selection") { store.insertArtboardFromSelection() }
                        .disabled(store.selection.isEmpty)
                    Divider()
                    Button("Vector") { store.tool = .pen }
                        .shortcut("vector")
                    Button("Text") { store.tool = .text }
                        .shortcut("insertText")
                    Button("Image…") { store.insertImage() }
                    Divider()
                    Button("Rectangle") { store.tool = .rect }
                        .shortcut("insertRect")
                    Button("Oval") { store.tool = .oval }
                        .shortcut("insertOval")
                    Button("Star") { store.insertStar() }
                    Button("Polygon") { store.insertPolygon() }
                } label: {
                    Label("Insert", systemImage: "plus")
                }
                .menuIndicator(.hidden)
                .help("Insert artboard, shape, vector, text or image")
                .disabled(store.source == nil)
            }
            // No tool picker. Insert ▸ Vector (P) starts drawing, and Escape or the
            // cursor button below stops — so a persistent three-way switch was one
            // redundant control and one that stood in for a point property.
            //
            // The badge names the mode and nothing else. It used to spell out both key
            // bindings, which made a wide strip of small grey text out of a thing whose
            // whole job is to be glanced at.
            ToolbarItem(placement: .principal) {
                if store.tool != .select {
                    HStack(spacing: 5) {
                        Image(systemName: store.tool.symbol).font(.caption)
                        Text(store.tool.title).font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(.tint.opacity(0.12), in: Capsule())
                    .help("\(store.tool.title) mode — press Esc to go back to the cursor")
                }
            }
            // The way out. Escape does the same thing, but only while the canvas has
            // the keyboard — after typing in the inspector there has to be something
            // to click.
            ToolbarItem {
                Button { store.tool = .select } label: {
                    Label("Select", systemImage: "cursorarrow")
                }
                .help(store.tool == .select ? "Select tool" : "Back to the cursor (Esc)")
                .foregroundStyle(store.tool == .select ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            // No Fit button: View ▸ Zoom to Fit already has it, and pages fit
            // themselves on arrival, so the toolbar copy was spending permanent space
            // on something you reach for once a session.
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
                .help(showCommandBar ? "Hide chat (⌘K)" : "Show chat (⌘K)")
                .symbolVariant(showCommandBar ? .fill : .none)
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
            // ⌘K toggles now that it starts open — otherwise the key does nothing
            // visible the first time you press it.
            showCommandBar.toggle()
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
                        railHeader("Accomplice Chat", count: nil)
                        ChatPanel().environmentObject(store)
                    }
                    .frame(minHeight: 200)
                }
            } else {
                properties
            }
        }

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

    }

    private var pageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader("Pages", count: store.source?.pageCount) {
                Button { store.addPage() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Add a page")
                    .accessibilityIdentifier("add-page")
                    .disabled(store.source == nil)
            }
            // Names and layer counts come from document.json, so the sidebar is
            // populated before any page geometry has been parsed.
            PageListView(pages: store.source?.pages ?? [],
                         selected: store.pageIndex,
                         store: store,
                         onRename: { i in
                             renamingPage = i
                             renameText = store.source?.pages[i].name ?? ""
                         })
                .alert("Rename Page", isPresented: Binding(
                    get: { renamingPage != nil },
                    set: { if !$0 { renamingPage = nil } })) {
                    TextField("Name", text: $renameText)
                    Button("Rename") {
                        if let i = renamingPage { store.renamePage(at: i, to: renameText) }
                        renamingPage = nil
                    }
                    Button("Cancel", role: .cancel) { renamingPage = nil }
                }
        }
    }

    private var layerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader("Layers", count: store.page?.layers.count)
            if let page = store.page {
                LayerOutline(nodes: page.layers.map(LayerNode.init),
                             revision: store.revision &+ store.pageToken,
                             selection: $store.selection,
                             store: store)
            } else {
                Spacer()
            }
        }
    }


    @ViewBuilder
    private func railHeader<Accessory: View>(_ title: String, count: Int?,
                                             @ViewBuilder accessory: () -> Accessory = { EmptyView() })
        -> some View {
        // Sentence case in the text colour, not tiny grey capitals. These are section
        // names you read at a glance while working, and Sketch has it right: they
        // belong to the content, not to the chrome.
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            if let count {
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            accessory()
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
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
                                pageToken: store.pageToken,
                                cropping: store.croppingID)
            Color.clear.accessibilityIdentifier("canvas").allowsHitTesting(false)
            if store.isLoading || store.isPageLoading {
                ProgressView().controlSize(.large).padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }

        // An overlay, not a safe-area inset with a bar behind it.
        //
        // A solid strip along the bottom was the last piece of the older idiom left in
        // the window: with the toolbar background gone it became the only thing drawing
        // a bar, and it cut the canvas short for the sake of two words. The status is
        // just text on the canvas now, the way the document title is just text in the
        // toolbar.
        .overlay(alignment: .bottom) {
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
            .padding(.horizontal, 14).padding(.vertical, 8)
            .allowsHitTesting(false)   // never in the way of the canvas underneath
        }
    }
}
