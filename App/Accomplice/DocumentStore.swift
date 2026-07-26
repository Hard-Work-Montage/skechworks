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

    func open(_ url: URL) {
        isLoading = true
        page = nil
        source = nil
        status = "Opening \(url.lastPathComponent)…"
        MissingFonts.reset()

        Task.detached(priority: .userInitiated) {
            var made: DocumentSource?
            var failure: String?

            // .acmplc.png first — it's the native format, and it only parses
            // document.json here, so this is fast regardless of document size. A
            // .sketch fails that and falls through; so does a PNG whose payload was
            // stripped, which is why the error has to distinguish them.
            do {
                made = try DocumentSource.acmplc(url: url)
            } catch {
                if url.pathExtension.lowercased() == "sketch" {
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

            let warnings = MissingFonts.all
            await MainActor.run { [made, failure] in
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
                self.isPageLoading = false
                if !warnings.isEmpty { self.fontWarnings = warnings }
            }
        }
    }

    // MARK: - Editing

    let undoManager = UndoManager()
    @Published var isDirty = false
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
    func save() {
        guard let src = source, let url else { return }
        isLoading = true
        status = "Saving…"
        let cover = coverPage
        Task.detached(priority: .userInitiated) {
            var opts = AcmplcFile.Options()
            opts.coverPage = cover
            do {
                let doc = src.fullDocument()
                let data = try AcmplcFile.write(document: doc, images: src.images, options: opts)
                try data.write(to: url)
                LaunchBinding.claim(url)
                await MainActor.run {
                    self.isLoading = false
                    self.isDirty = false
                    self.status = "Saved \(url.lastPathComponent)"
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.status = "Save failed: \(error)"
                    NSSound.beep()
                }
            }
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
