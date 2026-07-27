import AccompliceCore
import AppKit
import Foundation

/// Holds the open document. Deliberately not an NSDocument yet — this is a viewer, and
/// there is nothing to save. The moment editing lands this should become one, because
/// NSDocument is where autosave and version browsing come from for free, and those are
/// the mitigation for a stripped .acmplc.png.
@MainActor
final class DocumentStore: ObservableObject {

    @Published var source: DocumentSource?
    @Published var url: URL?
    @Published var pageIndex = 0 { didSet { loadCurrentPage() } }
    /// The selection. A set rather than a single id because boolean ops, aligning and
    /// bulk moves all act on several layers at once, and retrofitting that later would
    /// touch every edit path.
    @Published var selection: Set<String> = []

    enum Tool: String, CaseIterable {
        case select, pen, bend
        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .pen: return "pencil.tip"
            case .bend: return "point.topleft.down.to.point.bottomright.curvepath"
            }
        }
        var title: String {
            switch self {
            case .select: return "Select (V)"
            case .pen: return "Pen (P)"
            case .bend: return "Bend (B)"
            }
        }
    }
    @Published var tool: Tool = .select

    /// Convenience for the inspector, which shows one layer's properties.
    var selectedLayerID: String? {
        get { selection.count == 1 ? selection.first : nil }
        set { selection = newValue.map { [$0] } ?? [] }
    }

    func select(_ id: String?, extend: Bool = false) {
        guard let id else { if !extend { selection = [] }; return }
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if selection != [id] {
            selection = [id]
        }
    }
    @Published var status: String = "Open an .acmplc.png or a .sketch file"
    @Published var isLoading = false
    @Published var isPageLoading = false
    @Published var fontWarnings: [(String, String)] = []

    /// The page currently on screen, once parsed. Nil while a page is still being read.
    @Published private(set) var page: Page?

    /// Bumped whenever a DIFFERENT page becomes visible — a new document, or another
    /// page in the same one.
    ///
    /// Page NAME is not an identity: a blank document and an imported SVG are both
    /// "Page 1", so keying the canvas on the name meant opening one into the other
    /// never re-fitted the view and the artwork sat off-screen with nothing drawn.
    @Published private(set) var pageToken = 0

    /// Bumped on every edit. The canvas caches its composition (boolean ops are
    /// expensive), and page identity alone can't tell it the CONTENTS changed — so
    /// after a move the art would redraw from a stale composition while the selection
    /// frames used fresh geometry, and the two would disagree on screen.
    @Published private(set) var revision = 0

    /// Which page the file's PNG half shows. Preserved across saves — changing it
    /// would silently change how the document looks in Finder.
    private(set) var coverPage = 0

    var images: [String: Data] { source?.images ?? [:] }
    var pageCount: Int { source?.pageCount ?? 0 }

    /// A blank document: one page, no file behind it yet.
    func newDocument() {
        var doc = Document()
        doc.pages = [Page(name: "Page 1")]
        source = DocumentSource.eager(doc, images: [:])
        coverPage = 0
        url = nil
        undoManager.removeAllActions()
        isDirty = false
        canUndo = false; canRedo = false
        selection = []
        fontWarnings = []
        pageIndex = 0
        loadCurrentPage()
        status = "New document"
    }

    var displayName: String { url?.lastPathComponent ?? "Untitled" }

    func open(_ url: URL) {
        isLoading = true
        // Deliberately NOT clearing page/source here. Doing so meant a file that
        // turned out not to be openable — an image dropped on the window, say — wiped
        // the document you already had, unsaved work included. Nothing is discarded
        // until there's a replacement in hand.
        status = "Opening \(url.lastPathComponent)…"
        MissingFonts.reset()

        Task.detached(priority: .userInitiated) {
            var made: DocumentSource?
            var failure: String?
            var notes: [String] = []

            // .acmplc.png first — it's the native format, and it only parses
            // document.json here, so this is fast regardless of document size. A
            // .sketch fails that and falls through; so does a PNG whose payload was
            // stripped, which is why the error has to distinguish them.
            let ext = url.pathExtension.lowercased()
            if ext == "svg" {
                do {
                    let r = try SVGReader().read(url: url)
                    made = DocumentSource.eager(r.document, images: r.images)
                    notes = r.warnings
                } catch {
                    failure = "\(error)"
                }
            } else {
                do {
                    made = try DocumentSource.acmplc(url: url)
                } catch {
                    if ext == "sketch" {
                        var reader = SketchReader()
                        do {
                            let doc = try reader.read(url: url)
                            made = DocumentSource.eager(doc, images: reader.images)
                        } catch {
                            failure = "\(error)"
                        }
                    } else {
                        failure = "\(error)"
                    }
                }
            }

            let warnings = MissingFonts.all
            await MainActor.run { [made, failure, notes] in
                self.isLoading = false
                self.fontWarnings = warnings
                guard let src = made else {
                    self.status = failure ?? "Could not open \(url.lastPathComponent)"
                    NSSound.beep()
                    return
                }
                self.source = src
                self.coverPage = src.coverPage
                self.url = url
                self.undoManager.removeAllActions()
                self.isDirty = false
                self.canUndo = false
                self.canRedo = false
                self.selection = []
                self.status = "\(src.pageCount) page\(src.pageCount == 1 ? "" : "s")"
                    + (src.sourceApp.map { " · from \($0)" } ?? "")
                    + (notes.isEmpty ? "" : " · \(notes.count) note\(notes.count == 1 ? "" : "s")")
                // Imported SVG can't carry everything; say what was left out rather
                // than letting it look like a faithful import.
                if !notes.isEmpty { self.fontWarnings = notes.map { ("SVG", $0) } }
                // An imported SVG has no .acmplc.png behind it yet.
                if url.pathExtension.lowercased() == "svg" {
                    self.url = nil
                    self.isDirty = true
                }
                self.pageIndex = 0
                self.loadCurrentPage()
            }
        }
    }

    /// Parses the selected page off the main thread. Pages already parsed come back
    /// synchronously, so flipping between visited pages doesn't flicker.
    private func loadCurrentPage() {
        guard let src = source else { page = nil; return }
        let i = pageIndex
        if src.isLoaded(i) {
            page = src.page(at: i)
            pageToken += 1
            isPageLoading = false
            return
        }
        isPageLoading = true
        Task.detached(priority: .userInitiated) {
            let p = src.page(at: i)
            let warnings = MissingFonts.all
            await MainActor.run {
                guard self.pageIndex == i, self.source === src else { return }
                self.page = p
                self.pageToken += 1
                self.isPageLoading = false
                if !warnings.isEmpty { self.fontWarnings = warnings }
            }
        }
    }

    // MARK: - Editing

    let undoManager = UndoManager()
    @Published var isDirty = false
    /// Set when the user chooses "Don't Save", so the close can proceed.
    func discardChanges() { isDirty = false }
    @Published var canUndo = false
    @Published var canRedo = false

    /// Applies an edit to one layer and registers its inverse for undo.
    ///
    /// Undo works by snapshotting the whole layer before and after rather than
    /// diffing properties. A Layer is a value type, so a snapshot is cheap and
    /// correct by construction — no chance of an undo step that restores position
    /// but forgets the fill.
    func edit(_ layerID: String, actionName: String, _ body: (inout Layer) -> Void) {
        edit([layerID], actionName: actionName, body)
    }

    /// Applies the same change across several layers as ONE undo step — so moving a
    /// six-layer selection is one ⌘Z, not six.
    func edit(_ ids: [String], actionName: String, _ body: (inout Layer) -> Void) {
        guard var page, let src = source, !ids.isEmpty else { return }
        var before: [String: Layer] = [:], after: [String: Layer] = [:]
        for id in ids {
            guard let b = page.layer(id) else { continue }
            before[id] = b
            page.updateLayer(id) { body(&$0) }
            if let a = page.layer(id) { after[id] = a }
        }
        guard !before.isEmpty else { return }

        apply(page, at: pageIndex, src: src)
        registerUndo(restore: before, redo: after, pageIndex: pageIndex, actionName: actionName)
        revision += 1
        isDirty = true
        refreshUndoState()
    }

    // MARK: - Dragging

    /// A drag in progress: the layer as it was when the mouse went down.
    ///
    /// Dragging can't call `edit` per mouse-move — that would push one undo step per
    /// frame and recompose the page (~0.6s of CGPath booleans) on every tick. Instead
    /// the canvas previews the move itself, and the model is touched once on mouse-up.
    private var dragStart: (origins: [String: CGPoint], page: Int)?

    func beginDrag(_ id: String) {
        guard let page else { return }
        let ids = selection.contains(id) ? Array(selection) : [id]
        var origins: [String: CGPoint] = [:]
        for i in ids { if let l = page.layer(i) { origins[i] = l.frame.origin } }
        dragStart = (origins, pageIndex)
    }

    /// Commits the whole gesture as a single undo step, across the whole selection.
    func endDrag(offset: CGSize) {
        guard let start = dragStart else { return }
        dragStart = nil
        guard offset != .zero, pageIndex == start.page else { return }
        let origins = start.origins
        edit(Array(origins.keys), actionName: "Move") { l in
            guard let o = origins[l.id] else { return }
            l.frame.origin = CGPoint(x: o.x + offset.width, y: o.y + offset.height)
        }
    }

    func cancelDrag() { dragStart = nil }

    // MARK: - Resizing

    private var resizeStart: [String: CGRect] = [:]

    func beginResize() {
        guard let page else { return }
        resizeStart = [:]
        for id in selection { if let l = page.layer(id) { resizeStart[id] = l.frame } }
    }

    /// Scales the selection about `anchor` (the handle opposite the one being dragged),
    /// as one undo step. Layer.resize takes the contained geometry with it.
    func endResize(scale: CGSize, anchor: CGPoint) {
        let start = resizeStart
        resizeStart = [:]
        guard !start.isEmpty, scale.width != 1 || scale.height != 1 else { return }
        edit(Array(start.keys), actionName: "Resize") { l in
            guard let f = start[l.id] else { return }
            l.frame.origin = CGPoint(x: anchor.x + (f.minX - anchor.x) * scale.width,
                                     y: anchor.y + (f.minY - anchor.y) * scale.height)
            l.resize(to: CGSize(width: max(1, f.width * scale.width),
                                height: max(1, f.height * scale.height)))
        }
    }

    func cancelResize() { resizeStart = [:] }

    // MARK: - Adding and removing layers

    /// Appends a layer (the pen tool's output) as one undoable step.
    func addLayer(_ layer: Layer, actionName: String = "Draw Path") {
        guard var p = page, let src = source else { return }
        p.layers.append(layer)
        apply(p, at: pageIndex, src: src)
        revision += 1
        isDirty = true
        selection = [layer.id]
        let idx = pageIndex
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.removeLayer(layer.id, pageIndex: idx, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        refreshUndoState()
    }

    func removeLayer(_ id: String, pageIndex idx: Int, actionName: String = "Delete") {
        guard let src = source, var p = src.page(at: idx),
              let i = p.layers.firstIndex(where: { $0.id == id }) else { return }
        let removed = p.layers.remove(at: i)
        if pageIndex != idx { pageIndex = idx }
        apply(p, at: idx, src: src)
        revision += 1
        isDirty = true
        selection.remove(id)
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.reinsertLayer(removed, at: i, pageIndex: idx, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        refreshUndoState()
    }

    /// Deletes everything selected as ONE undo step, restoring each layer to its exact
    /// place in the tree on undo — including nested ones.
    func deleteSelection() {
        guard let src = source, var p = page, !selection.isEmpty else { return }
        var removed: [(parent: String?, index: Int, layer: Layer)] = []
        // Deepest-last so re-inserting in reverse rebuilds the tree correctly.
        for id in selection { if let r = p.removeLayer(id) { removed.append(r) } }
        guard !removed.isEmpty else { return }

        apply(p, at: pageIndex, src: src)
        revision += 1
        isDirty = true
        selection = []
        let idx = pageIndex
        let name = removed.count == 1 ? "Delete \(removed[0].layer.name)" : "Delete \(removed.count) Layers"
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restore(removed, pageIndex: idx, actionName: name) }
        }
        undoManager.setActionName(name)
        refreshUndoState()
    }

    private func restore(_ items: [(parent: String?, index: Int, layer: Layer)],
                         pageIndex idx: Int, actionName: String) {
        guard let src = source, var p = src.page(at: idx) else { return }
        for r in items.reversed() { p.insertLayer(r.layer, parent: r.parent, index: r.index) }
        if pageIndex != idx { pageIndex = idx }
        apply(p, at: idx, src: src)
        revision += 1
        isDirty = true
        selection = Set(items.map { $0.layer.id })
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.deleteSelection() }
        }
        undoManager.setActionName(actionName)
        refreshUndoState()
    }

    private func reinsertLayer(_ layer: Layer, at i: Int, pageIndex idx: Int, actionName: String) {
        guard let src = source, var p = src.page(at: idx) else { return }
        p.layers.insert(layer, at: min(i, p.layers.count))
        if pageIndex != idx { pageIndex = idx }
        apply(p, at: idx, src: src)
        revision += 1
        isDirty = true
        selection = [layer.id]
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.removeLayer(layer.id, pageIndex: idx, actionName: actionName) }
        }
        refreshUndoState()
    }

    // MARK: - Scripting

    /// Runs a batch of commands as ONE undo step.
    ///
    /// Whole-batch undo matters more here than anywhere else in the app: a model can
    /// touch two hundred layers in a sentence, and unpicking that click by click is
    /// not an undo story anyone would accept.
    @discardableResult
    func run(_ commands: [DocumentCommand]) -> String {
        guard !commands.isEmpty, page != nil else { return "Nothing to do." }
        var report: [String] = []
        var pendingSelection: Set<String>?
        let name = commands.count == 1 ? commands[0].summary : "\(commands.count) Changes"
        let currentSelection = selection

        // A model naturally writes "select these, then delete" — two commands, the
        // second with no selector. An empty query matches EVERYTHING, so taken
        // literally that deletes the document. Carry the batch's last selection
        // forward instead, which is what was meant, and refuse an unscoped
        // destructive command outright.
        var scope: Set<String>? = currentSelection.isEmpty ? nil : currentSelection

        mutatePage(name) { p in
            for c in commands {
                let ids: [String]
                if c.query.isEmpty {
                    guard let inherited = scope, !inherited.isEmpty else {
                        report.append("\(c.summary): refused — no layers specified")
                        continue
                    }
                    // Preserve document order rather than Set order.
                    ids = p.find(LayerQuery()).filter { inherited.contains($0) }
                } else {
                    ids = p.find(c.query, selection: currentSelection)
                }
                if ids.isEmpty {
                    report.append("\(c.summary): no matching layers")
                    continue
                }
                if case .select = c {
                    pendingSelection = Set(ids)
                    scope = Set(ids)
                } else {
                    DocumentStore.apply(c, ids: ids, to: &p)
                }
                report.append("\(c.summary): \(ids.count) layer\(ids.count == 1 ? "" : "s")")
            }
        }
        if let sel = pendingSelection { selection = sel }
        return report.isEmpty ? "Nothing matched." : report.joined(separator: "\n")
    }

    /// Split out from `run` purely so the type checker can cope — a switch this wide
    /// with closures inline defeats it.
    private static func apply(_ c: DocumentCommand, ids: [String], to p: inout Page) {
        let set = Set(ids)
        switch c {
        case .select:
            break   // handled by the caller; selection isn't a document change

        case .delete:
            for id in ids { p.removeLayer(id) }

        case .setFill(_, let hex):
            guard let col = SVGReader.color(hex, alpha: 1) else { return }
            for id in ids {
                p.updateLayer(id) { $0.style.fills = [Fill(paint: .color(col))] }
            }

        case .setStroke(_, let hex, let width):
            guard let col = SVGReader.color(hex, alpha: 1) else { return }
            for id in ids {
                p.updateLayer(id) { l in
                    var b = l.style.borders.first ?? Border()
                    b.color = col
                    if let w = width { b.thickness = CGFloat(w) }
                    l.style.borders = [b]
                }
            }

        case .setOpacity(_, let v):
            let clamped = max(0, min(1, CGFloat(v)))
            for id in ids { p.updateLayer(id) { $0.style.opacity = clamped } }

        case .setVisible(_, let v):
            for id in ids { p.updateLayer(id) { $0.isVisible = v } }

        case .rename(_, let pattern):
            for (i, id) in ids.enumerated() {
                p.updateLayer(id) { l in
                    var out = pattern.replacingOccurrences(of: "{i}", with: String(i + 1))
                    out = out.replacingOccurrences(of: "{name}", with: l.name)
                    l.name = out
                }
            }

        case .move(_, let dx, let dy):
            for id in ids {
                p.updateLayer(id) { l in
                    l.frame.origin = CGPoint(x: l.frame.minX + CGFloat(dx),
                                             y: l.frame.minY + CGFloat(dy))
                }
            }

        case .resize(_, let w, let h):
            for id in ids {
                p.updateLayer(id) { l in
                    let newW: CGFloat = w.map { CGFloat($0) } ?? l.frame.width
                    let newH: CGFloat = h.map { CGFloat($0) } ?? l.frame.height
                    l.resize(to: CGSize(width: newW, height: newH))
                }
            }

        case .align(_, let edge):
            let map: [String: AlignEdge] = [
                "left": .left, "centre": .horizontalCentre, "center": .horizontalCentre,
                "right": .right, "top": .top, "middle": .verticalMiddle, "bottom": .bottom,
            ]
            if let e = map[edge.lowercased()] { p.align(set, to: e) }

        case .distribute(_, let axis):
            let vertical = axis.lowercased().hasPrefix("v")
            p.distribute(set, along: vertical ? .vertical : .horizontal)

        case .order(_, let dir):
            switch dir.lowercased() {
            case "front": p.bringToFront(set)
            case "back": p.sendToBack(set)
            case "forward": p.bringForward(set)
            default: p.sendBackward(set)
            }

        case .group(_, let gname):
            p.group(set, named: gname ?? "Group")

        case .ungroup:
            for id in ids { p.ungroup(id) }
        }
    }

    /// What a model is shown before it decides anything.
    func describeDocument() -> String {
        guard let page else { return "No document open." }
        var out = "document: \(displayName)\n"
        out += "pages: \((source?.pages ?? []).map(\.name).joined(separator: ", "))\n"
        out += "selection: \(selection.count) layer\(selection.count == 1 ? "" : "s")\n\n"
        out += page.describe()
        return out
    }

    // MARK: - Arrange

    /// Structural edits (reordering, grouping) change the shape of the tree rather
    /// than one layer's properties, so undo snapshots the whole page. A layer-by-layer
    /// diff can't express "this moved out of that group".
    func mutatePage(_ actionName: String, _ body: (inout Page) -> Void) {
        guard let src = source, var p = page else { return }
        let before = p.layers
        body(&p)
        guard !layersEqual(before, p.layers) else { return }
        apply(p, at: pageIndex, src: src)
        revision += 1
        isDirty = true
        registerPageUndo(before, pageIndex: pageIndex, actionName: actionName)
        refreshUndoState()
    }

    private func registerPageUndo(_ layers: [Layer], pageIndex idx: Int, actionName: String) {
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                guard let src = store.source, var p = src.page(at: idx) else { return }
                let redo = p.layers
                p.layers = layers
                if store.pageIndex != idx { store.pageIndex = idx }
                store.apply(p, at: idx, src: src)
                store.revision += 1
                store.isDirty = true
                store.registerPageUndo(redo, pageIndex: idx, actionName: actionName)
                store.refreshUndoState()
            }
        }
        undoManager.setActionName(actionName)
    }

    /// Cheap structural comparison, so a no-op arrange doesn't push an undo step.
    private func layersEqual(_ a: [Layer], _ b: [Layer]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.id != y.id || x.frame != y.frame { return false }
        }
        return true
    }

    func bringForward()  { mutatePage("Bring Forward")  { $0.bringForward(selection) } }
    func sendBackward()  { mutatePage("Send Backward")  { $0.sendBackward(selection) } }
    func bringToFront()  { mutatePage("Bring to Front") { $0.bringToFront(selection) } }
    func sendToBack()    { mutatePage("Send to Back")   { $0.sendToBack(selection) } }

    func align(_ edge: AlignEdge, _ name: String) {
        mutatePage("Align \(name)") { $0.align(selection, to: edge) }
    }

    func distribute(_ axis: Axis, _ name: String) {
        mutatePage("Distribute \(name)") { $0.distribute(selection, along: axis) }
    }

    func groupSelection() {
        guard selection.count >= 1 else { return }
        var made: String?
        mutatePage("Group") { made = $0.group(selection) }
        if let made { selection = [made] }
    }

    func ungroupSelection() {
        let targets = selection
        var freed: [String] = []
        mutatePage("Ungroup") { p in
            for id in targets { freed.append(contentsOf: p.ungroup(id)) }
        }
        if !freed.isEmpty { selection = Set(freed) }
    }

    func toggleLockOrHide(hide: Bool) {
        guard !selection.isEmpty, let page else { return }
        let anyVisible = selection.compactMap { page.layer($0) }.contains { $0.isVisible }
        if hide {
            edit(Array(selection), actionName: anyVisible ? "Hide Layers" : "Show Layers") {
                $0.isVisible = !anyVisible
            }
        }
    }

    // MARK: - Clipboard

    static let pasteboardType = NSPasteboard.PasteboardType("com.accomplice.layers")

    var canCopy: Bool { !selection.isEmpty }
    var canPaste: Bool {
        let pb = NSPasteboard.general
        return pb.data(forType: Self.pasteboardType) != nil || pb.string(forType: .string) != nil
    }

    func copySelection() {
        guard let page, !selection.isEmpty else { return }
        let layers = selection.compactMap { page.layer($0) }
        guard !layers.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        // Native type for full fidelity; SVG alongside it so a shape can be pasted
        // straight into another program.
        if let d = try? AcmplcFile.encodeClipboard(layers: layers, images: images) {
            pb.setData(d, forType: Self.pasteboardType)
        }
        var scratch = Page(name: "clip")
        scratch.layers = layers
        pb.setString(SVGWriter(images: images).svg(page: scratch), forType: .string)
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    func paste() {
        let pb = NSPasteboard.general
        guard let src = source, var p = page,
              let data = pb.data(forType: Self.pasteboardType),
              let (layers, assets) = AcmplcFile.decodeClipboard(data), !layers.isEmpty else {
            pasteExternal()
            return
        }

        // Fresh ids, nudged so a paste-in-place isn't invisible.
        let offset: CGFloat = 20
        let fresh = layers.map { l -> Layer in
            var c = l.withNewIDs()
            c.frame.origin = CGPoint(x: c.frame.minX + offset, y: c.frame.minY + offset)
            return c
        }
        // Bring any referenced images across; pasting between documents otherwise
        // yields a layer pointing at bytes this document has never seen.
        var newSource = src
        for (k, v) in assets where src.images[k] == nil {
            newSource = newSource.adding(image: v, key: k)
        }
        source = newSource
        p.layers.append(contentsOf: fresh)
        apply(p, at: pageIndex, src: newSource)
        revision += 1
        isDirty = true
        selection = Set(fresh.map(\.id))

        let idx = pageIndex
        let ids = fresh.map(\.id)
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.selection = Set(ids)
                store.deleteSelection()
            }
        }
        undoManager.setActionName(fresh.count == 1 ? "Paste" : "Paste \(fresh.count) Layers")
        refreshUndoState()
    }

    /// Pasting something that didn't come from Accomplice: an image copied out of
    /// Preview, Finder, a browser.
    private func pasteExternal() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for u in urls where !Self.isDocument(u) {
                if let d = try? Data(contentsOf: u),
                   placeImage(d, name: u.deletingPathExtension().lastPathComponent) { return }
            }
            if let doc = urls.first(where: Self.isDocument) { open(doc); return }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let d = pb.data(forType: type), placeImage(d, name: "Pasted Image") { return }
        }
    }

    func duplicateSelection() {
        copySelection()
        paste()
        undoManager.setActionName("Duplicate")
    }

    func selectAll() {
        guard let page else { return }
        selection = Set(page.layers.map(\.id))
    }

    // MARK: - Insert

    /// Where a newly inserted layer lands: the middle of the current content, or the
    /// origin on an empty page.
    private func insertionPoint(_ size: CGSize) -> CGPoint {
        let b = page?.contentBounds() ?? CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let hasContent = !(page?.layers.isEmpty ?? true)
        let c = hasContent ? CGPoint(x: b.midX, y: b.midY) : CGPoint(x: b.midX, y: b.midY)
        return CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
    }

    func insertArtboard() {
        let size = CGSize(width: 500, height: 500)
        var l = Layer(kind: .group([]))
        l.name = "Artboard"
        l.isArtboard = true
        l.backgroundColor = Color(r: 1, g: 1, b: 1, a: 1)
        l.frame = CGRect(origin: insertionPoint(size), size: size)
        addLayer(l, actionName: "Insert Artboard")
    }

    func insertRectangle() {
        let size = CGSize(width: 200, height: 200)
        let p = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        var l = Layer(kind: .path(p, closed: true))
        l.name = "Rectangle"
        l.frame = CGRect(origin: insertionPoint(size), size: size)
        l.style.fills = [Fill(paint: .color(.black))]
        addLayer(l, actionName: "Insert Rectangle")
    }

    func insertOval() {
        let size = CGSize(width: 200, height: 200)
        let p = CGPath(ellipseIn: CGRect(origin: .zero, size: size), transform: nil)
        var l = Layer(kind: .path(p, closed: true))
        l.name = "Oval"
        l.frame = CGRect(origin: insertionPoint(size), size: size)
        l.style.fills = [Fill(paint: .color(.black))]
        addLayer(l, actionName: "Insert Oval")
    }

    func insertText() {
        var run = TextRun()
        run.string = "Type something"
        run.fontName = "Helvetica"
        run.fontSize = 48
        run.alignment = .center
        let size = CGSize(width: 400, height: 70)
        var l = Layer(kind: .text(run))
        l.name = "Text"
        l.frame = CGRect(origin: insertionPoint(size), size: size)
        addLayer(l, actionName: "Insert Text")
    }

    func insertImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif]
        panel.canChooseDirectories = false
        panel.message = "Choose an image to place"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        placeImage(data, name: url.deletingPathExtension().lastPathComponent)
    }

    /// Places image bytes as a bitmap layer. Shared by the insert menu, drag-and-drop
    /// and paste, so all three behave identically.
    @discardableResult
    func placeImage(_ data: Data, name: String, at origin: CGPoint? = nil) -> Bool {
        guard let src = source, BitmapImage.load(data) != nil else { return false }

        // Content-addressed, matching how the format stores assets, so placing the same
        // photo twice doesn't duplicate the bytes.
        let key = "images/\(Zip.crc32(data))-\(data.count).png"
        let display = BitmapImage.load(data)?.displaySize ?? CGSize(width: 400, height: 400)
        let scale = min(1, 800 / max(display.width, display.height))
        let size = CGSize(width: display.width * scale, height: display.height * scale)

        source = src.adding(image: data, key: key)
        var l = Layer(kind: .bitmap(imageRef: key))
        l.name = name.isEmpty ? "Image" : name
        l.frame = CGRect(origin: origin ?? insertionPoint(size), size: size)
        addLayer(l, actionName: "Place Image")
        return true
    }

    static func isDocument(_ url: URL) -> Bool { DocumentKind.isDocument(url) }

    /// A dropped file: open documents, place everything else we can decode.
    func acceptDropped(_ url: URL) {
        if Self.isDocument(url) { open(url); return }
        guard let data = try? Data(contentsOf: url),
              placeImage(data, name: url.deletingPathExtension().lastPathComponent) else {
            status = "Can't place \(url.lastPathComponent)"
            NSSound.beep()
            return
        }
    }

    /// Builds a layer from points drawn on the canvas (page space).
    ///
    /// Geometry is stored in the layer's OWN space with the frame carrying the offset,
    /// so the path is normalised to its bounding box on the way in.
    func commitDrawnPath(_ vp: VectorPath) {
        guard vp.points.count >= 2 else { return }
        let cg = vp.cgPath()
        let box = cg.boundingBoxOfPath
        guard box.width.isFinite, box.height.isFinite else { return }
        let local = cg.transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))

        var l = Layer(kind: .path(local, closed: vp.closed))
        l.name = vp.closed ? "Path" : "Line"
        l.frame = box
        if vp.closed {
            l.style.fills = [Fill(paint: .color(.black))]
        } else {
            var b = Border()
            b.color = .black
            b.thickness = 1
            l.style.borders = [b]
        }
        addLayer(l)
    }

    /// Writes an edited path back to its layer, keeping the frame in step with the
    /// new bounds so the layer box doesn't drift away from its artwork.
    func commitEditedPath(_ vp: VectorPath, layerID: String, actionName: String) {
        let cg = vp.cgPath()
        let box = cg.boundingBoxOfPath
        guard box.width.isFinite, box.height.isFinite else { return }
        edit(layerID, actionName: actionName) { l in
            let origin = CGPoint(x: l.frame.minX + box.minX, y: l.frame.minY + box.minY)
            let local = cg.transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
            l.kind = .path(local, closed: vp.closed)
            l.frame = CGRect(origin: origin, size: box.size)
        }
    }

    /// Arrow-key nudge. Shift moves by 10 the way every design tool does.
    func nudge(dx: CGFloat, dy: CGFloat) {
        guard !selection.isEmpty else { return }
        edit(Array(selection), actionName: "Nudge") {
            $0.frame.origin = CGPoint(x: $0.frame.minX + dx, y: $0.frame.minY + dy)
        }
    }

    /// Everything the marquee touched.
    func selectAll(in rect: CGRect, on page: Page, extend: Bool) {
        var hits: Set<String> = []
        for l in page.layers where l.isVisible {
            let t = Compose.transform(l)
            let box = (Compose.resolvedPath(l)?.transformed(by: t).boundingBoxOfPath)
                ?? CGRect(origin: .zero, size: l.frame.size).applying(t)
            if rect.intersects(box) { hits.insert(l.id) }
        }
        selection = extend ? selection.union(hits) : hits
    }

    private func registerUndo(restore: [String: Layer], redo: [String: Layer],
                              pageIndex idx: Int, actionName: String) {
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.replaceLayers(restore, pageIndex: idx)
                // Registering during undo is what makes redo work.
                store.registerUndo(restore: redo, redo: restore,
                                   pageIndex: idx, actionName: actionName)
                store.isDirty = true
                store.refreshUndoState()
            }
        }
        undoManager.setActionName(actionName)
    }

    private func replaceLayers(_ layers: [String: Layer], pageIndex idx: Int) {
        guard let src = source else { return }
        if pageIndex != idx { pageIndex = idx }
        guard var p = src.page(at: idx) else { return }
        for (id, l) in layers { p.updateLayer(id) { $0 = l } }
        apply(p, at: idx, src: src)
        revision += 1
        // Restore the selection the edit applied to, so undo puts you back where you were.
        selection = Set(layers.keys)
    }

    private func apply(_ p: Page, at idx: Int, src: DocumentSource) {
        src.replacePage(p, at: idx)
        if idx == pageIndex { page = p }
    }

    private func refreshUndoState() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
    }

    func undo() { undoManager.undo(); refreshUndoState() }
    func redo() { undoManager.redo(); refreshUndoState() }

    // MARK: - Save

    /// Rewrites the whole .acmplc.png. Every page is parsed first — including ones
    /// never opened — so untouched pages survive a save unchanged.
    /// `completion(true)` only when bytes actually reached disk — the close prompt
    /// needs to know, since a cancelled Save As must leave the window open.
    func save(completion: ((Bool) -> Void)? = nil) {
        guard source != nil else { completion?(false); return }
        guard url != nil else { saveAs(completion: completion); return }
        writeToDisk(completion: completion)
    }

    /// Asks where to put a document that has never been written.
    func saveAs(completion: ((Bool) -> Void)? = nil) {
        guard source != nil else { completion?(false); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (url?.lastPathComponent ?? "Untitled.acmplc.png")
        panel.message = "Save as an Accomplice document"
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, var out = panel.url else { completion?(false); return }
        // Keep the compound extension: it's what makes the file read as an image
        // everywhere, which is the whole point of the format.
        if !out.lastPathComponent.hasSuffix(".acmplc.png") {
            out = out.deletingPathExtension()
                .appendingPathExtension("acmplc.png")
        }
        url = out
        writeToDisk(completion: completion)
    }

    /// The completion stays on the main actor throughout — the heavy work happens in
    /// a detached task whose result is a plain value, so no non-Sendable closure has
    /// to cross an isolation boundary.
    private func writeToDisk(completion: ((Bool) -> Void)? = nil) {
        guard let src = source, let url else { completion?(false); return }
        isLoading = true
        status = "Saving…"
        var opts = AcmplcFile.Options()
        opts.coverPage = coverPage
        let options = opts

        Task { @MainActor in
            let outcome: (ok: Bool, message: String) = await Task.detached(priority: .userInitiated) {
                do {
                    // Every page is parsed first — including ones never opened — so
                    // untouched pages survive a save unchanged.
                    let doc = src.fullDocument()
                    let data = try AcmplcFile.write(document: doc, images: src.images, options: options)
                    try data.write(to: url)
                    LaunchBinding.claim(url)
                    return (true, "Saved \(url.lastPathComponent)")
                } catch {
                    return (false, "Save failed: \(error)")
                }
            }.value

            self.isLoading = false
            self.status = outcome.message
            if outcome.ok { self.isDirty = false } else { NSSound.beep() }
            completion?(outcome.ok)
        }
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = []
        p.allowsOtherFileTypes = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.message = "Open an Accomplice document (.acmplc.png) or a Sketch file"
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    // MARK: - Export

    func exportCurrentPage() {
        guard let page else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = slug(page.name) + ".svg"
        panel.message = "Export “\(page.name)” as SVG"
        guard panel.runModal() == .OK, let out = panel.url else { return }
        let svg = SVGWriter(images: images).svg(page: page)
        do {
            try Data(svg.utf8).write(to: out)
            status = "Exported \(out.lastPathComponent)"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    enum ExportFormat: String, CaseIterable, Identifiable {
        case svg, png, jpg
        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
    }

    /// Exports each selected layer to its own file, the way Sketch's Export Selected
    /// works — one artboard, one file, sized to that artboard rather than the page.
    func exportSelected(format: ExportFormat = .svg, scale: CGFloat = 1) {
        guard let page, !selection.isEmpty else { return }
        let targets = selection.compactMap { page.isolate($0) }
        guard !targets.isEmpty else { return }
        exportIsolated(targets, format: format, scale: scale, what: "selection")
    }

    /// Every artboard on the current page, named after the artboard.
    func exportArtboards(format: ExportFormat = .svg, scale: CGFloat = 1) {
        guard let page else { return }
        let boards = page.artboards
        guard !boards.isEmpty else {
            status = "This page has no artboards"
            NSSound.beep()
            return
        }
        let targets = boards.compactMap { page.isolate($0.id) }
        exportIsolated(targets, format: format, scale: scale, what: "artboards")
    }

    private func exportIsolated(_ targets: [(page: Page, bounds: CGRect, rotatedAncestor: Bool)],
                                format: ExportFormat, scale: CGFloat, what: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Export \(targets.count) \(what) as \(format.title)"
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let imgs = images
        var written = 0
        var rotatedWarnings = 0
        for t in targets {
            if t.rotatedAncestor { rotatedWarnings += 1 }
            let base = slug(t.page.name)
            let suffix = scale == 1 ? "" : "@\(Int(scale))x"
            let file = dir.appendingPathComponent("\(base)\(suffix).\(format.rawValue)")
            switch format {
            case .svg:
                let svg = SVGWriter(images: imgs).svg(page: t.page, bounds: t.bounds)
                if (try? Data(svg.utf8).write(to: file)) != nil { written += 1 }
            case .png, .jpg:
                let r = Renderer(images: imgs,
                                 background: format == .jpg ? Color(r: 1, g: 1, b: 1, a: 1) : nil)
                let maxDim = max(t.bounds.width, t.bounds.height) * scale
                guard let img = r.render(page: t.page, maxDimension: maxDim, bounds: t.bounds),
                      let data = format == .png ? Renderer.png(img) : Renderer.jpeg(img) else { continue }
                if (try? data.write(to: file)) != nil { written += 1 }
            }
        }
        status = "Exported \(written) \(format.title)\(written == 1 ? "" : "s")"
            + (rotatedWarnings > 0 ? " · \(rotatedWarnings) had a rotated parent and may be offset" : "")
    }

    func exportAllPages() {
        guard let src = source else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Export all \(src.pageCount) pages as SVG"
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        // The one operation that legitimately needs every page, so it's also the one
        // that pays the parse cost — off the main thread, with progress.
        isLoading = true
        status = "Exporting \(src.pageCount) pages…"
        let images = src.images
        Task.detached(priority: .userInitiated) {
            let w = SVGWriter(images: images)
            var n = 0
            for i in 0..<src.pageCount {
                guard let p = src.page(at: i) else { continue }
                let f = dir.appendingPathComponent(String(format: "%03d-%@.svg", i, Self.slugify(p.name)))
                if (try? Data(w.svg(page: p).utf8).write(to: f)) != nil { n += 1 }
            }
            await MainActor.run {
                self.isLoading = false
                self.status = "Exported \(n) SVG\(n == 1 ? "" : "s")"
            }
        }
    }

    nonisolated static func slugify(_ s: String) -> String {
        let base = String(s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
        return base.isEmpty ? "page" : base
    }

    private func slug(_ s: String) -> String { Self.slugify(s) }
}

// MARK: - Layer tree for display

struct LayerNode: Identifiable {
    let id: String
    let name: String
    let kindLabel: String
    let systemImage: String
    let isVisible: Bool
    let children: [LayerNode]?

    init(_ l: Layer) {
        id = l.id
        isVisible = l.isVisible
        switch l.kind {
        case .group(let k):
            kindLabel = l.isArtboard ? "Artboard" : "Group"
            systemImage = l.isArtboard ? "rectangle.dashed" : "folder"
            children = k.isEmpty ? nil : k.map(LayerNode.init)
        case .shapeGroup(let k, _):
            kindLabel = "Combined"; systemImage = "square.on.circle"
            children = k.isEmpty ? nil : k.map(LayerNode.init)
        case .path:
            kindLabel = "Path"; systemImage = "scribble"; children = nil
        case .text(let t):
            kindLabel = t.string.replacingOccurrences(of: "\n", with: " ")
            systemImage = "textformat"; children = nil
        case .bitmap:
            kindLabel = "Image"; systemImage = "photo"; children = nil
        }
        name = l.name.isEmpty ? kindLabel : l.name
    }
}
