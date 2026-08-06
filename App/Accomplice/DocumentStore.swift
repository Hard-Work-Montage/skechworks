import AccompliceCore
import AppKit
import Foundation
import UniformTypeIdentifiers

/// Holds the open document. Deliberately not an NSDocument yet — this is a viewer, and
/// there is nothing to save. The moment editing lands this should become one, because
/// NSDocument is where autosave and version browsing come from for free, and those are
/// the mitigation for a stripped .acmplc.png.
@MainActor
final class DocumentStore: ObservableObject {

    @Published var source: DocumentSource?
    @Published var url: URL? {
        didSet { AppDelegate.shared?.recordSession() }
    }
    /// The window this document lives in, set by WindowTabbing. How menu commands
    /// find the document the user is actually looking at.
    weak var window: NSWindow?
    @Published var pageIndex = 0 { didSet { loadCurrentPage() } }
    /// The selection. A set rather than a single id because boolean ops, aligning and
    /// bulk moves all act on several layers at once, and retrofitting that later would
    /// touch every edit path.
    @Published var selection: Set<String> = [] {
        // Selecting something else ends whatever was being dragged, so the next
        // colour change starts its own undo step rather than joining the last one.
        didSet { if selection != oldValue { endCoalescing() } }
    }

    enum Tool: String, CaseIterable {
        case select, pen, erase, remove, rect, oval, text
        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .pen: return "pencil.tip"
            case .erase: return "eraser"
            case .remove: return "wand.and.stars"
            case .rect: return "rectangle"
            case .oval: return "circle"
            case .text: return "textformat"
            }
        }
        var title: String {
            switch self {
            case .select: return "Select"
            case .pen: return "Vector"
            case .erase: return "Erase"
            case .remove: return "Remove"
            case .rect: return "Rectangle"
            case .oval: return "Oval"
            case .text: return "Text"
            }
        }

        /// Tools that make something new where you put it, rather than acting on
        /// artwork that's already there.
        var draws: Bool { self == .rect || self == .oval || self == .text }

        /// The word `add` knows this shape by.
        var kind: String {
            switch self {
            case .oval: return "ellipse"
            case .text: return "text"
            default: return "rect"
            }
        }
    }
    @Published var tool: Tool = .select
    /// A text layer that was just placed and should open for typing as soon as the
    /// canvas has it. Set here, consumed by the canvas on its next update — the
    /// layer doesn't exist in the view's copy of the page until then.
    @Published var pendingTextEdit: String?

    /// Something the person asked for didn't happen, and they need to know now.
    ///
    /// The status line is right for progress and for what just worked. It is wrong
    /// for a failure with a fix attached: it sits below the canvas in small grey
    /// type, so a request that quietly did nothing looks like a request that
    /// quietly did nothing.
    struct Alarm: Identifiable {
        let id = UUID()
        var title: String
        var detail: String
        /// True when the fix lives in Settings, so the alert can offer to go there.
        var settings = false
    }
    @Published var alarm: Alarm?

    /// Reports a failure the way it deserves.
    ///
    /// Anything the person can act on gets a modal and, where the fix is in
    /// Settings, a button that opens it. Raw transport detail never reaches either:
    /// "HTTP 401" followed by a JSON envelope is a thing to be read past to find
    /// the one sentence that matters.
    func report(_ error: Error, doing what: String) {
        let said = error.localizedDescription
        let inSettings: Bool
        if let failure = error as? ModelConnector.Failure {
            switch failure {
            case .notSignedIn, .noKey, .cannotSee, .outOfCredits: inSettings = true
            default: inSettings = false
            }
        } else {
            inSettings = false
        }
        alarm = Alarm(title: "\(what) couldn't finish", detail: said, settings: inSettings)
        status = said
    }
    /// Brush settings, kept across strokes and documents — you pick a size once.
    /// UserDefaults directly rather than @AppStorage: this is a store, not a view.
    var eraseRadius: Double {
        get { UserDefaults.standard.object(forKey: "eraseRadius") as? Double ?? 24 }
        set { UserDefaults.standard.set(newValue, forKey: "eraseRadius"); objectWillChange.send() }
    }
    var eraseSoftness: Double {
        get { UserDefaults.standard.object(forKey: "eraseSoftness") as? Double ?? 0.5 }
        set { UserDefaults.standard.set(newValue, forKey: "eraseSoftness"); objectWillChange.send() }
    }
    /// Zoom is a request, not a value — the canvas owns the magnification because
    /// only it knows the viewport. See ZoomIntent.
    @Published var zoomRequest = ZoomRequest()

    /// The conversation, owned by the document rather than by the panel.
    ///
    /// It used to be a @StateObject inside ChatPanel, which SwiftUI destroys along with
    /// the view — so hiding chat threw the conversation away. It lasts as long as the
    /// document is open now, and goes when you clear it or close the window.
    let chat = ChatSession()

    /// The point currently being edited on the canvas, so the inspector can show its
    /// type. Point Type is a property of the point, not a tool — which is why the
    /// bend tool that used to stand in for it is gone.
    struct EditingPoint: Equatable {
        var index: Int
        var mode: CurveMode
    }
    @Published var editingPoint: EditingPoint?
    /// A requested change of point type, applied by the canvas that owns the path.
    @Published var pointModeRequest: (serial: Int, mode: CurveMode)? {
        didSet { if pointModeRequest == nil { return } }
    }

    func setPointMode(_ m: CurveMode) {
        pointModeRequest = (serial: (pointModeRequest?.serial ?? 0) + 1, mode: m)
    }

    func zoom(_ intent: ZoomIntent) {
        zoomRequest = ZoomRequest(serial: zoomRequest.serial + 1, intent: intent)
    }

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

    /// Takes a document straight in, without a file behind it.
    ///
    /// newDocument() only ever makes an empty one, so there was no way to put a store
    /// into a known state — which is part of why this layer had no tests.
    func adopt(_ doc: Document, images: [String: Data]) {
        source = DocumentSource.eager(doc, images: images)
        coverPage = 0
        url = nil
        undoManager.removeAllActions()
        isDirty = false
        canUndo = false; canRedo = false
        selection = []
        pageIndex = 0
        loadCurrentPage()
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
            var importedImage = false

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
                    } else if let data = try? Data(contentsOf: url),
                              let bitmap = BitmapImage.load(data) {
                        // A plain image: open it as a picture on the canvas, at its
                        // own size, in a fresh untitled document. This is also the
                        // soft landing for a stripped .acmplc.png — the document is
                        // gone but the picture survives, so show the picture rather
                        // than an empty window.
                        let key = "images/\(Zip.crc32(data))-\(data.count).png"
                        var l = Layer(kind: .bitmap(imageRef: key))
                        l.name = AcmplcFile.baseName(url.lastPathComponent)
                        l.frame = CGRect(origin: .zero, size: bitmap.displaySize)
                        var page = Page(name: "Page 1")
                        page.layers = [l]
                        var doc = Document()
                        doc.pages = [page]
                        made = DocumentSource.eager(doc, images: [key: data])
                        importedImage = true
                        // Only a file claiming to BE a document warrants the warning.
                        if url.lastPathComponent.lowercased().contains(".acmplc") {
                            notes = ["\(error)"]
                        }
                    } else {
                        failure = "\(error)"
                    }
                }
            }

            let warnings = MissingFonts.all
            await MainActor.run { [made, failure, notes, importedImage] in
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
                RecentDocuments.shared.note(url)
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
                if !notes.isEmpty { self.fontWarnings = notes.map { ("Import", $0) } }
                // An imported SVG or plain image has no .acmplc.png behind it yet —
                // saving must ask where, never overwrite the original in place.
                if url.pathExtension.lowercased() == "svg" || importedImage {
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
    @Published var isDirty = false {
        // The whole autosave contract in one place: dirty work schedules a recovery
        // snapshot, and anything that makes the document clean — a save, Don't Save,
        // adopting a fresh document — throws the snapshot away.
        didSet { if isDirty { scheduleAutosave() } else { clearRecovery() } }
    }
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
    func edit(_ layerID: String, actionName: String,
              coalescingAs key: String? = nil,
              _ body: (inout Layer) -> Void) {
        edit([layerID], actionName: actionName, coalescingAs: key, body)
    }

    /// The continuous edit in progress, if any.
    ///
    /// A colour well fires on every tick of the drag. Registering an undo step per tick
    /// would make ⌘Z walk backwards through every shade you passed through on the way,
    /// which is not what "undo" means to anyone. So the first edit under a given key
    /// registers the step and the rest ride on it: one gesture, one undo.
    private var coalescing: String?

    /// The redo snapshot of the open coalesced step, kept current as the drag runs.
    /// A box rather than a value because the registered undo closure has already
    /// captured it by the time the second tick arrives.
    private final class RedoBox {
        var layers: [String: Layer]
        init(_ l: [String: Layer]) { layers = l }
    }
    private var coalescingRedo: RedoBox?

    /// Ends any run of coalesced edits, so the next one starts a fresh undo step.
    /// Called when the selection or page changes, and after undo/redo.
    func endCoalescing() { coalescing = nil; coalescingRedo = nil }

    /// Applies the same change across several layers as ONE undo step — so moving a
    /// six-layer selection is one ⌘Z, not six.
    ///
    /// Pass `coalescingAs` for a value being dragged: consecutive edits sharing a key
    /// collapse into the step the first one registered.
    func edit(_ ids: [String], actionName: String,
              coalescingAs key: String? = nil,
              _ body: (inout Layer) -> Void) {
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
        if key != nil, key == coalescing, let open = coalescingRedo {
            // Riding on the step the first tick registered. Its redo snapshot has to
            // keep up with the drag, or redo would jump back to the first shade.
            open.layers = after
        } else {
            let box = RedoBox(after)
            registerUndo(restore: before, redo: box, pageIndex: pageIndex, actionName: actionName)
            coalescingRedo = key == nil ? nil : box
        }
        coalescing = key
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
        mutatePage("Move") { p in
            for (id, o) in origins {
                let d = Self.inParentSpace(CGPoint(x: offset.width, y: offset.height), of: id, on: p)
                p.updateLayer(id) {
                    $0.frame.origin = CGPoint(x: o.x + d.x, y: o.y + d.y)
                }
            }
            // The drop decides the parent, the way Sketch's frames do: a layer whose
            // centre leaves its artboard escapes to the canvas root (otherwise the
            // board keeps clipping it into an invisible selection box), and one
            // dropped onto a different board moves in. Same rule paste follows.
            for id in origins.keys {
                guard let l = p.layer(id), !l.isArtboard else { continue }
                let ancestors = p.ancestors(of: id)
                // If a dragged container carries this layer, the container decides.
                if ancestors.contains(where: { origins.keys.contains($0) }) { continue }
                guard let abs = p.absoluteOrigin(of: id) else { continue }
                let centre = CGPoint(x: abs.x + l.frame.width / 2, y: abs.y + l.frame.height / 2)
                let target = p.artboard(containing: centre)
                let current = ancestors.last(where: { p.layer($0)?.isArtboard == true })
                if let target {
                    if current != target.id {
                        _ = p.reparent([id], into: target.id, at: p.children(of: target.id).count)
                    }
                } else if current != nil {
                    _ = p.reparent([id], into: nil, at: p.layers.count)
                }
            }
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
        mutatePage("Resize") { page in
            page.scale(Array(start.keys), about: anchor, by: scale, from: start)
        }
    }

    func cancelResize() { resizeStart = [:] }

    // MARK: - Rotating

    private var rotateStart: (angles: [String: CGFloat], frames: [String: CGRect]) = ([:], [:])

    func beginRotate() {
        guard let page else { return }
        var angles: [String: CGFloat] = [:], frames: [String: CGRect] = [:]
        for id in selection {
            if let l = page.layer(id) { angles[id] = l.rotation; frames[id] = l.frame }
        }
        rotateStart = (angles, frames)
    }

    /// One undo step for the whole turn, however many frames the drag took.
    func endRotate(degrees: CGFloat, centre: CGPoint) {
        let start = rotateStart
        rotateStart = ([:], [:])
        guard !start.angles.isEmpty, degrees != 0 else { return }
        mutatePage("Rotate") { page in
            page.rotate(Array(start.angles.keys), about: centre, by: degrees,
                        startAngles: start.angles, startFrames: start.frames)
        }
    }

    // MARK: - Adding and removing layers

    /// Appends a layer (the pen tool's output, a placed image) as one undoable step.
    ///
    /// Frames arrive in page coordinates, and the layer lands in whatever artboard it
    /// was drawn on — see Page.adoptIntoArtboard, which is also where the frame gets
    /// converted into that artboard's space.
    func addLayer(_ layer: Layer, actionName: String = "Draw Path") {
        guard var p = page, let src = source else { return }
        p.layers.append(layer)
        p.adoptIntoArtboard(layer.id)
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

    /// Removes a layer from anywhere in the tree.
    ///
    /// Anywhere, not just the top level: now that a drawn shape lands inside the
    /// artboard it was drawn on, undoing the drawing has to be able to reach it there.
    func removeLayer(_ id: String, pageIndex idx: Int, actionName: String = "Delete") {
        guard let src = source, var p = src.page(at: idx),
              let gone = p.removeLayer(id) else { return }
        if pageIndex != idx { pageIndex = idx }
        apply(p, at: idx, src: src)
        revision += 1
        isDirty = true
        selection.remove(id)
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.reinsertLayer(gone.layer, parent: gone.parent, at: gone.index,
                                    pageIndex: idx, actionName: actionName)
            }
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

    private func reinsertLayer(_ layer: Layer, parent: String?, at i: Int,
                               pageIndex idx: Int, actionName: String) {
        guard let src = source, var p = src.page(at: idx) else { return }
        p.insertLayer(layer, parent: parent, index: i)
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
        let name = commands.count == 1 ? commands[0].summary : "\(commands.count) Changes"
        var outcome = CommandRun()
        mutatePage(name) { p in
            outcome = p.run(commands, selection: self.selection)
        }
        if let sel = outcome.selection { selection = sel }
        return outcome.report
    }

    /// How many layers a batch would touch, without touching them.
    func countAffected(_ commands: [DocumentCommand]) -> Int {
        guard let page else { return 0 }
        var touched: Set<String> = []
        var scope: Set<String>? = selection.isEmpty ? nil : selection
        for c in commands {
            let ids: [String]
            if c.query.isEmpty {
                ids = Array(scope ?? [])
            } else {
                ids = page.find(c.query, selection: selection)
            }
            if case .select = c { scope = Set(ids) } else { touched.formUnion(ids) }
        }
        return touched.count
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
        let signatureBefore = p.contentSignature
        body(&p)
        guard p.contentSignature != signatureBefore else { return }
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

    func bringForward()  { mutatePage("Bring Forward")  { $0.bringForward(selection) } }
    func sendBackward()  { mutatePage("Send Backward")  { $0.sendBackward(selection) } }
    func bringToFront()  { mutatePage("Bring to Front") { $0.bringToFront(selection) } }
    func sendToBack()    { mutatePage("Send to Back")   { $0.sendToBack(selection) } }

    func align(_ edge: AlignEdge, _ name: String) {
        mutatePage("Align \(name)") { $0.align(selection, to: edge) }
    }

    func flipSelection(horizontal: Bool) {
        guard !selection.isEmpty else { return }
        edit(Array(selection), actionName: horizontal ? "Flip Horizontal" : "Flip Vertical") {
            if horizontal { $0.flipH.toggle() } else { $0.flipV.toggle() }
        }
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

    /// Marks the selection as a clipping mask, or clears it.
    ///
    /// A mask clips the layers above it inside its own group, which is what makes the
    /// circle-plus-bitmap arrangement work: circle underneath, marked as the mask,
    /// bitmap above it and clipped to the circle.
    func toggleMask() {
        guard let page, let first = selection.compactMap({ page.layer($0) }).first else { return }
        let on = !first.hasClippingMask
        let ids = selection
        mutatePage(on ? "Use as Mask" : "Remove Mask") { p in
            for id in ids { p.updateLayer(id) { $0.hasClippingMask = on } }
            // A mask clips what's above it, and you almost always draw the shape last,
            // so it starts on top with nothing above it to clip. Left where it is,
            // "Use as Mask" would appear to do nothing at all. One undo puts it back.
            if on { p.sendToBack(ids) }
        }
    }

    /// Exempts a layer from the mask above it — Sketch's "Ignore Mask".
    func toggleIgnoreMask() {
        guard let page, let first = selection.compactMap({ page.layer($0) }).first else { return }
        let on = !first.breaksMaskChain
        let ids = selection
        mutatePage(on ? "Ignore Mask" : "Honour Mask") { p in
            for id in ids { p.updateLayer(id) { $0.breaksMaskChain = on } }
        }
    }

    /// Moves layers in the tree — reordering, or dragging into an artboard or group.
    @discardableResult
    func moveLayers(_ ids: [String], into parent: String?, at index: Int) -> Bool {
        var ok = false
        mutatePage("Move Layer") { page in
            ok = page.reparent(ids, into: parent, at: index)
        }
        return ok
    }

    /// A new shadow, with the settings you'd have typed anyway: soft, black, slightly
    /// below. A shadow added at 0/0/0 looks like nothing happened.
    // MARK: - Fills and borders

    /// Sets a solid fill colour. `coalescing` is on by default because this is nearly
    /// always driven by a colour well being dragged.
    func setFillColor(_ id: String, at index: Int, to c: Color) {
        edit(id, actionName: "Change Fill", coalescingAs: "fill:\(id):\(index)") { l in
            guard l.style.fills.indices.contains(index) else { return }
            l.style.fills[index].paint = .color(c)
        }
    }

    /// Moves one stop of a gradient. Position stays put; only the colour changes.
    func setGradientStopColor(_ id: String, fill index: Int, stop: Int, to c: Color) {
        edit(id, actionName: "Change Gradient", coalescingAs: "grad:\(id):\(index):\(stop)") { l in
            guard l.style.fills.indices.contains(index),
                  case .gradient(var g) = l.style.fills[index].paint,
                  g.stops.indices.contains(stop) else { return }
            g.stops[stop].color = c
            l.style.fills[index].paint = .gradient(g)
        }
    }

    func setBorderColor(_ id: String, at index: Int, to c: Color) {
        edit(id, actionName: "Change Border", coalescingAs: "border:\(id):\(index)") { l in
            guard l.style.borders.indices.contains(index) else { return }
            l.style.borders[index].color = c
        }
    }

    func setBorderThickness(_ id: String, at index: Int, to w: CGFloat) {
        edit(id, actionName: "Change Border Width") { l in
            guard l.style.borders.indices.contains(index) else { return }
            l.style.borders[index].thickness = max(0, w)
        }
    }

    func setBorderPosition(_ id: String, at index: Int, to p: BorderPosition) {
        edit(id, actionName: "Change Border Position") { l in
            guard l.style.borders.indices.contains(index) else { return }
            l.style.borders[index].position = p
        }
    }

    /// Rounds the corners of a shape. The stored outline keeps its sharp ones — see
    /// Layer.cornerRadius — so this stays a number you can change your mind about.
    func setCornerRadius(_ id: String, to r: CGFloat) {
        edit(id, actionName: "Change Corner Radius", coalescingAs: "corner:\(id)") {
            $0.cornerRadius = max(0, r)
        }
    }

    func setCornerStyle(_ id: String, to s: CornerStyle) {
        edit(id, actionName: "Change Corner Style") { $0.cornerStyle = s }
    }

    func setArtboardBackground(_ id: String, to c: Color) {
        edit(id, actionName: "Change Artboard Color", coalescingAs: "artboard:\(id)") {
            $0.backgroundColor = c
        }
    }

    /// A new fill starts mid-grey rather than black: black on a white artboard reads as
    /// "it worked", and black on a dark one reads as "nothing happened".
    func addFill(_ id: String) {
        edit(id, actionName: "Add Fill") {
            $0.style.fills.append(Fill(paint: .color(Color(r: 0.5, g: 0.5, b: 0.5, a: 1))))
        }
    }

    func removeFill(_ id: String, at index: Int) {
        edit(id, actionName: "Remove Fill") {
            guard $0.style.fills.indices.contains(index) else { return }
            $0.style.fills.remove(at: index)
        }
    }

    func addBorder(_ id: String) {
        edit(id, actionName: "Add Border") {
            var b = Border()
            b.color = .black
            b.thickness = 1
            $0.style.borders.append(b)
        }
    }

    func removeBorder(_ id: String, at index: Int) {
        edit(id, actionName: "Remove Border") {
            guard $0.style.borders.indices.contains(index) else { return }
            $0.style.borders.remove(at: index)
        }
    }

    func addShadow(_ id: String) {
        edit(id, actionName: "Add Shadow") { l in
            var s = Shadow()
            s.color = Color(r: 0, g: 0, b: 0, a: 0.25)
            s.offset = CGSize(width: 0, height: 4)
            s.blur = 8
            l.style.shadows.append(s)
        }
    }

    func removeShadow(_ id: String, at index: Int) {
        edit(id, actionName: "Remove Shadow") { l in
            guard l.style.shadows.indices.contains(index) else { return }
            l.style.shadows.remove(at: index)
        }
    }

    func editShadow(_ id: String, at index: Int, actionName: String,
                    coalescingAs key: String? = nil,
                    _ body: @escaping (inout Shadow) -> Void) {
        edit([id], actionName: actionName, coalescingAs: key) { l in
            guard l.style.shadows.indices.contains(index) else { return }
            body(&l.style.shadows[index])
        }
    }

    // MARK: - Pages

    /// Adds an empty page after the current one and switches to it.
    func addPage() {
        guard let src = source else { return }
        let made = Page(name: uniquePageName("Page"))
        let at = src.insert(made, at: pageIndex + 1)
        pageDidChange(select: at, actionName: "Add Page")
    }

    func duplicatePage() {
        guard let src = source, var copy = src.page(at: pageIndex) else { return }
        // Fresh ids throughout: two pages sharing layer ids would have selection and
        // editing act on both at once.
        copy.layers = copy.layers.map { $0.withNewIDs() }
        copy.name = uniquePageName(copy.name)
        let at = src.insert(copy, at: pageIndex + 1)
        pageDidChange(select: at, actionName: "Duplicate Page")
    }

    /// Removes a page, and puts it back on undo — the one page operation that loses
    /// work if it's wrong.
    func deletePage(at index: Int) {
        guard let src = source, src.pageCount > 1,
              let removed = src.remove(at: index) else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.source?.insert(removed, at: index)
                store.pageDidChange(select: index, actionName: "Delete Page")
            }
        }
        undoManager.setActionName("Delete Page")
        pageDidChange(select: min(index, src.pageCount - 1), actionName: "Delete Page")
    }

    /// Reorders pages, and puts them back on undo.
    @discardableResult
    func movePage(from: Int, to: Int) -> Bool {
        guard let src = source, src.move(from: from, to: to) else { return false }
        let landed = max(0, min(to, src.pageCount - 1))
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.movePage(from: landed, to: from) }
        }
        undoManager.setActionName("Move Page")
        pageDidChange(select: landed, actionName: "Move Page")
        return true
    }

    func renamePage(at index: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let src = source else { return }
        let was = src.pages[index].name
        src.rename(at: index, to: trimmed)
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.renamePage(at: index, to: was) }
        }
        undoManager.setActionName("Rename Page")
        pageDidChange(select: pageIndex, actionName: "Rename Page")
    }

    /// "Page 2", "Page 2 copy", "Page 2 copy 2" — never a duplicate, because two pages
    /// with one name is confusing in a list that shows nothing else about them.
    private func uniquePageName(_ wanted: String) -> String {
        let taken = Set(source?.pages.map(\.name) ?? [])
        if !taken.contains(wanted), wanted != "Page" { return wanted }
        var n = (source?.pageCount ?? 0) + 1
        var candidate = "\(wanted == "Page" ? "Page" : wanted + " copy") \(n)"
        if wanted != "Page", !taken.contains(wanted + " copy") { return wanted + " copy" }
        while taken.contains(candidate) {
            n += 1
            candidate = "\(wanted == "Page" ? "Page" : wanted + " copy") \(n)"
        }
        return candidate
    }

    private func pageDidChange(select index: Int, actionName: String) {
        objectWillChange.send()
        pageIndex = max(0, min(index, (source?.pageCount ?? 1) - 1))
        isDirty = true
        revision += 1
        selection = []
        loadCurrentPage()
        refreshUndoState()
    }

    // MARK: - Boolean operations

    /// Combines the selection into one shape. Selects the result, so the next thing
    /// you do acts on what you just made.
    func combineSelection(_ op: BooleanOp) {
        guard selection.count >= 2 else { return }
        let ids = Array(selection)
        var made: String?
        mutatePage(Page.combinedName(op)) { made = $0.combine(ids, op: op) }
        if let made { selection = [made] }
    }

    /// Replaces a combined shape with the single path it draws.
    func flattenSelection() {
        let ids = selection
        mutatePage("Flatten") { page in
            for id in ids { page.flattenShape(id) }
        }
    }

    /// Edits the text run inside a text layer — the unwrap/rewrap that every text
    /// property change needs, in one place.
    func editText(_ id: String, _ actionName: String, coalescingAs key: String? = nil,
                  _ body: (inout TextRun) -> Void) {
        edit(id, actionName: actionName, coalescingAs: key) { l in
            guard case .text(var t) = l.kind else { return }
            body(&t)
            l.kind = .text(t)
        }
    }

    func setBooleanOp(_ id: String, to op: BooleanOp) {
        edit(id, actionName: "Change Boolean") { $0.booleanOp = op }
    }

    /// Tools ▸ Vectorize: the selected bitmap goes out as pixels and comes back
    /// as editable paths, grouped, sitting exactly where the bitmap sits.
    func vectorizeSelection(style: String = "color") {
        guard let id = selectedLayerID, let page,
              let l = page.layer(id), case .bitmap(let ref) = l.kind,
              let raw = images[ref] else {
            status = "Select one image layer to vectorize"
            return
        }
        // Vectorize what the user SEES. A cropped or adjusted bitmap must go out
        // as its baked display rendition — sending the original bytes traced the
        // uncropped photo and handed back shapes for parts that aren't on canvas.
        let data: Data
        if l.hasBitmapAdjustments,
           let baked = BitmapAdjust.displayImage(data: raw, ref: ref, layer: l),
           let png = Renderer.png(baked) {
            data = png
        } else {
            data = raw
        }
        guard !(Credentials.get(.accompliceToken) ?? "").isEmpty else {
            status = "Vectorize needs your Accomplice account — connect it in Settings ▸ Model"
            return
        }
        status = "Vectorizing… this takes a minute or two"
        let frame = l.frame
        Task { @MainActor in
            do {
                let result = try await ModelConnector.vectorize(png: data, style: style)
                guard let svgData = result.svg.data(using: .utf8) else {
                    status = "Vectorize failed: unreadable SVG"
                    return
                }
                let read = try SVGReader().read(data: svgData)
                var kids = read.document.pages.first?.layers ?? []
                // The tracer's SVG nests groups that mean nothing — ungrouping a
                // trace later exploded into a hundred shells. Inline them so the
                // result is one flat group of paths.
                func inline(_ ls: [Layer]) -> [Layer] {
                    ls.flatMap { l -> [Layer] in
                        guard case .group(let k) = l.kind, !l.isArtboard else { return [l] }
                        return inline(k).map { child in
                            var c = child
                            c.frame.origin.x += l.frame.minX
                            c.frame.origin.y += l.frame.minY
                            return c
                        }
                    }
                }
                kids = inline(kids)
                guard !kids.isEmpty else {
                    status = "Vectorize produced no shapes"
                    return
                }
                // The trace is in the flattened image's pixel space. Group it,
                // then size the group to the bitmap's frame so it lands exactly
                // on top of what it traced.
                let bounds = kids.map(\.frame).reduce(CGRect.null) { $0.union($1) }
                for i in kids.indices {
                    kids[i].frame.origin.x -= bounds.minX
                    kids[i].frame.origin.y -= bounds.minY
                }
                var group = Layer(kind: .group(kids))
                group.name = l.name.isEmpty ? "Vectorized" : "\(l.name) vector"
                group.frame = CGRect(origin: .zero, size: bounds.size)
                group.resize(to: frame.size)
                group.frame.origin = frame.origin

                mutatePage("Vectorize") { p in
                    let parent = p.ancestors(of: id).last
                    let index = p.children(of: parent).firstIndex { $0.id == id }
                    p.insertLayer(group, parent: parent, index: (index ?? 0) + 1)
                }
                selection = [group.id]
                if let left = result.remaining {
                    status = "Vectorized · $\(String(format: "%.2f", left)) in credits left"
                } else {
                    status = "Vectorized"
                }
            } catch {
                status = "Vectorize failed: \(error.localizedDescription)"
            }
        }
    }

    /// Tools ▸ AI Draw: the selected bitmap is looked at and redrawn as shapes.
    ///
    /// Sibling of Vectorize rather than a replacement. Vectorize is a hammer and
    /// gives correct pixels as hundreds of paths; this gives a few named shapes
    /// that are still real ellipses and strokes. Which one you want depends on
    /// whether you intend to edit the result.
    func aiDrawSelection() {
        guard let id = selectedLayerID, let page,
              let l = page.layer(id), case .bitmap(let ref) = l.kind,
              let raw = images[ref] else {
            status = "Select one image layer to draw"
            return
        }
        // Redraw what the user SEES, the same rule Vectorize learned: a cropped or
        // adjusted bitmap has to go out as its baked rendition.
        let data: Data
        if l.hasBitmapAdjustments,
           let baked = BitmapAdjust.displayImage(data: raw, ref: ref, layer: l),
           let png = Renderer.png(baked) {
            data = png
        } else {
            data = raw
        }
        guard let source = BitmapImage.load(data)?.image else {
            status = "That image can't be read"
            return
        }
        let connector = ModelConnector(settings: .current)
        guard connector.settings.backend != .ollama else {
            status = "AI Draw needs OpenRouter or your Accomplice account — a model on this Mac can't see the picture"
            return
        }

        let frame = l.frame
        let name = l.name
        status = "Looking at the picture…"
        Task { @MainActor in
            do {
                let outcome = try await AIDraw.trace(source: source, size: frame.size,
                                                     connector: connector) { self.status = $0 }
                var kids = outcome.layers
                let bounds = kids.map(\.frame).reduce(CGRect.null) { $0.union($1) }
                guard !bounds.isNull else {
                    status = "AI Draw produced no shapes"
                    return
                }
                for i in kids.indices {
                    kids[i].frame.origin.x -= bounds.minX
                    kids[i].frame.origin.y -= bounds.minY
                }
                var group = Layer(kind: .group(kids))
                group.name = name.isEmpty ? "Drawing" : "\(name) drawn"
                group.frame = CGRect(origin: .zero, size: bounds.size)
                // It drew in the bitmap's own space, so the group lands where the
                // bitmap sits, offset by wherever inside it the drawing ended up.
                group.frame.origin = CGPoint(x: frame.minX + bounds.minX, y: frame.minY + bounds.minY)

                mutatePage("AI Draw") { p in
                    let parent = p.ancestors(of: id).last
                    let index = p.children(of: parent).firstIndex { $0.id == id }
                    p.insertLayer(group, parent: parent, index: (index ?? 0) + 1)
                }
                selection = [group.id]
                let match = Int((outcome.score * 100).rounded())
                let shapes = kids.count == 1 ? "1 shape" : "\(kids.count) shapes"
                status = "Drew \(shapes), \(match)% match after \(outcome.passes) passes"
                    + (outcome.say.isEmpty ? "" : " · \(outcome.say)")
            } catch {
                report(error, doing: "AI Draw")
            }
        }
    }

    /// Tools ▸ Remove: the boxed part of a bitmap goes to the account service
    /// with the whole image; the service works out what the box means to remove
    /// and sends the image back with it painted out. Only the boxed region can
    /// change, so the swap is safe to drop straight over the old pixels.
    func removeRegion(_ id: String, rect: CGRect) {
        guard rect.width > 1, rect.height > 1,
              let page, let l = page.layer(id), case .bitmap(let ref) = l.kind,
              let raw = images[ref] else { return }
        // Send the pixels the user boxed, which are the pixels they SEE: bake
        // orientation, adjustments and crop the way the canvas draws them. This
        // also guarantees PNG going out; the stored bytes may be JPEG or HEIC.
        guard let baked = BitmapAdjust.displayImage(data: raw, ref: ref, layer: l),
              let data = Renderer.png(baked) else {
            status = "Can't read that image"
            return
        }
        guard !(Credentials.get(.accompliceToken) ?? "").isEmpty else {
            status = "Remove needs your Accomplice account. Connect it in Settings ▸ Model"
            return
        }
        // The box in unit coordinates: layer space spans the frame, y-down like
        // the image, so the ratio is all the server needs.
        let unit = CGRect(x: rect.minX / l.frame.width, y: rect.minY / l.frame.height,
                          width: rect.width / l.frame.width, height: rect.height / l.frame.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard unit.width > 0.001, unit.height > 0.001 else { return }
        status = "Removing… this takes a minute or two"
        Task { @MainActor in
            do {
                let result = try await ModelConnector.remove(png: data, rect: unit)
                guard let src = source, BitmapImage.load(result.png) != nil else {
                    status = "Remove failed: unreadable image"
                    return
                }
                let key = "images/\(Zip.crc32(result.png))-\(result.png.count).png"
                source = src.adding(image: result.png, key: key)
                edit(id, actionName: "Remove") { layer in
                    layer.kind = .bitmap(imageRef: key)
                    // The reply has the adjustments and crop baked in; leaving
                    // them on would apply them twice.
                    layer.brightness = 0
                    layer.contrast = 1
                    layer.saturation = 1
                    layer.cropRect = nil
                }
                if let left = result.remaining {
                    status = "Removed · $\(String(format: "%.2f", left)) in credits left"
                } else {
                    status = "Removed"
                }
            } catch {
                status = "Remove failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Perspective (⌘-drag a bitmap's corner handle)

    /// Moves one warp corner to a unit-space point, coalesced so the whole drag
    /// is a single undo step.
    func warpCorner(_ id: String, corner: Int, to unit: CGPoint) {
        guard (0...3).contains(corner) else { return }
        edit(id, actionName: "Distort", coalescingAs: "warp-\(id)") { l in
            guard case .bitmap = l.kind else { return }
            var c = l.warpCorners ?? [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                                      CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
            c[corner] = unit
            l.warpCorners = c
        }
    }

    func flattenDistort() {
        edit(Array(selection), actionName: "Flatten Distort") { $0.warpCorners = nil }
    }

    // MARK: - Pixel selection (double-click a bitmap)

    /// The bitmap whose pixels are being marquee-selected, Fireworks style.
    /// Entered by double-clicking a selected bitmap; left by Escape.
    @Published var pixelSelectID: String?
    /// The current box, in the layer's own coordinates.
    var pixelSelectRect: CGRect?

    func enterPixelSelect(_ id: String) {
        guard let page, let l = page.layer(id), case .bitmap = l.kind else { return }
        pixelSelectID = id
        pixelSelectRect = nil
        selection = [id]
        status = "Drag a box · ⌘C copies those pixels · ⌘V pastes over them · Esc leaves"
    }

    func exitPixelSelect() {
        pixelSelectID = nil
        pixelSelectRect = nil
        status = ""
    }

    /// The boxed region as pixels, cut from the bitmap as displayed — adjustments
    /// and crop baked, so what copies is what the user sees.
    private func pixelRegionImage() -> CGImage? {
        guard let id = pixelSelectID, let rect = pixelSelectRect, let page,
              let l = page.layer(id), case .bitmap(let ref) = l.kind,
              let raw = images[ref],
              let baked = BitmapAdjust.displayImage(data: raw, ref: ref, layer: l),
              l.frame.width > 0, l.frame.height > 0 else { return nil }
        let sx = CGFloat(baked.width) / l.frame.width
        let sy = CGFloat(baked.height) / l.frame.height
        let px = CGRect(x: rect.minX * sx, y: rect.minY * sy,
                        width: rect.width * sx, height: rect.height * sy).integral
        return baked.cropping(to: px)
    }

    /// ⌘C in pixel-select mode: the boxed pixels go out as a plain image, so they
    /// paste back here or into any other app.
    func copyPixelSelection() -> Bool {
        guard pixelSelectID != nil else { return false }
        guard let cg = pixelRegionImage(), let png = Renderer.png(cg) else {
            status = "Drag a box over the pixels first"
            return true
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        status = "Copied \(cg.width)×\(cg.height) pixels"
        return true
    }

    /// ⌘V in pixel-select mode: clipboard pixels land as a new bitmap layer sitting
    /// exactly on the box — paste-over, the Fireworks gesture.
    func pastePixelSelection() -> Bool {
        guard let id = pixelSelectID, let rect = pixelSelectRect else { return false }
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              BitmapImage.load(data) != nil,
              let src = source, let page, let l = page.layer(id) else { return false }
        let key = "images/\(Zip.crc32(data))-\(data.count).png"
        source = src.adding(image: data, key: key)
        var pasted = Layer(kind: .bitmap(imageRef: key))
        pasted.name = "Pasted pixels"
        // The box is layer-local; the source's frame is parent-relative, so their
        // sum places the new layer over the box whatever container they're in.
        pasted.frame = CGRect(x: l.frame.origin.x + rect.minX,
                              y: l.frame.origin.y + rect.minY,
                              width: rect.width, height: rect.height)
        mutatePage("Paste Pixels") { p in
            let parent = p.ancestors(of: id).last
            let index = p.children(of: parent).firstIndex { $0.id == id }
            p.insertLayer(pasted, parent: parent, index: (index ?? 0) + 1)
        }
        selection = [pasted.id]
        status = "Pasted over the box"
        return true
    }

    /// The bitmap being cropped on canvas, if any. Entered from the inspector,
    /// left by Enter (commit) or Escape (never mind).
    @Published var croppingID: String?

    /// Applies a crop chosen on canvas. `unit` is the kept region in the CURRENT
    /// visible image's coordinates, so successive crops compose; the frame shrinks
    /// to the kept region so nothing moves on screen.
    func applyCrop(_ id: String, unit u: CGRect) {
        edit(id, actionName: "Crop Image") { l in
            let old = l.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            l.cropRect = CGRect(x: old.minX + u.minX * old.width,
                                y: old.minY + u.minY * old.height,
                                width: max(0.01, u.width * old.width),
                                height: max(0.01, u.height * old.height))
            l.frame = CGRect(x: l.frame.minX + u.minX * l.frame.width,
                             y: l.frame.minY + u.minY * l.frame.height,
                             width: max(1, u.width * l.frame.width),
                             height: max(1, u.height * l.frame.height))
        }
        croppingID = nil
    }

    /// Uncrops: the full image returns, growing the frame back around the kept
    /// region so the visible part stays where it was.
    func removeCrop(_ id: String) {
        edit(id, actionName: "Remove Crop") { l in
            guard let c = l.cropRect, c.width > 0, c.height > 0 else { return }
            l.frame = CGRect(x: l.frame.minX - c.minX * (l.frame.width / c.width),
                             y: l.frame.minY - c.minY * (l.frame.height / c.height),
                             width: l.frame.width / c.width,
                             height: l.frame.height / c.height)
            l.cropRect = nil
        }
    }

    /// A rectangular erase patch — the marquee, for straight-edged cuts.
    func eraseRect(_ id: String, rect: CGRect) {
        guard rect.width > 1, rect.height > 1 else { return }
        edit(id, actionName: "Erase Area") { l in
            guard case .bitmap = l.kind else { return }
            l.erased.append(EraseStroke(rect: rect))
        }
    }

    /// Records an erase stroke against a bitmap layer.
    func erase(_ id: String, points: [CGPoint]) {
        guard points.count >= 1 else { return }
        edit(id, actionName: "Erase") { l in
            guard case .bitmap = l.kind else { return }
            l.erased.append(EraseStroke(points: points,
                                        radius: CGFloat(self.eraseRadius),
                                        softness: CGFloat(self.eraseSoftness)))
        }
    }

    /// Throws away every erase on the selection, which is the thing a destructive
    /// eraser could never offer.
    func clearErasing() {
        let ids = selection
        mutatePage("Restore Erased") { page in
            for id in ids { page.updateLayer(id) { $0.erased = [] } }
        }
    }

    /// Renames a layer, for the layer list and its context menu.
    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit(id, actionName: "Rename Layer") { $0.name = trimmed }
    }

    /// Locks when any of the selection is loose, unlocks when all are locked —
    /// the same one-button logic hide uses.
    func toggleLock() {
        guard !selection.isEmpty, let page else { return }
        let anyUnlocked = selection.compactMap { page.layer($0) }.contains { !$0.isLocked }
        edit(Array(selection), actionName: anyUnlocked ? "Lock" : "Unlock") {
            $0.isLocked = anyUnlocked
        }
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
        if copyPixelSelection() { return }
        guard let page, !selection.isEmpty else { return }
        // Copied out in page coordinates. A frame relative to an artboard means nothing
        // once it's on the clipboard, and pasting one anywhere else threw it by that
        // artboard's offset; paste puts it back into whatever it lands on.
        //
        // In DOCUMENT order, back to front — selection is a Set, and encoding it in
        // hash order meant paste restacked the copy however the hashes fell (the
        // background ellipse landed on top of the art it sat behind).
        let paintOrder = Dictionary(uniqueKeysWithValues:
            page.find(LayerQuery()).enumerated().map { ($1, $0) })
        let layers = selection.sorted { (paintOrder[$0] ?? .max) < (paintOrder[$1] ?? .max) }
            .compactMap { id -> Layer? in
            guard var l = page.layer(id) else { return nil }
            if let absolute = page.absoluteOrigin(of: id) { l.frame.origin = absolute }
            return l
        }
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

    func paste(at targetOrigin: CGPoint? = nil) {
        if pastePixelSelection() { return }
        let pb = NSPasteboard.general
        guard let src = source, var p = page,
              let data = pb.data(forType: Self.pasteboardType),
              let (layers, assets) = AcmplcFile.decodeClipboard(data), !layers.isEmpty else {
            pasteExternal()
            return
        }

        // Pasting with an artboard selected drops the copy INTO that board: at the
        // same relative spot it held on its source board, or centred when it came
        // from loose canvas. Selecting a board and pasting is the "put it there"
        // gesture — without this the copy just landed back where it came from.
        var targetBoard: Layer?
        if targetOrigin == nil, selection.count == 1, let sel = selection.first,
           let l = p.layer(sel), l.isArtboard { targetBoard = l }

        let bounds = layers.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        // Plain paste: nudged so a paste-in-place isn't invisible.
        var shift = CGPoint(x: 20, y: 20)
        if let targetOrigin {
            // An exact landing spot wins over every other placement rule.
            shift = CGPoint(x: targetOrigin.x - bounds.minX, y: targetOrigin.y - bounds.minY)
        } else if let board = targetBoard {
            let srcBoard = p.artboard(containing: CGPoint(x: bounds.midX, y: bounds.midY))
            if srcBoard?.id == board.id {
                targetBoard = nil    // pasting onto its own board: plain paste
            } else if let src = srcBoard {
                shift = CGPoint(x: board.frame.minX - src.frame.minX,
                                y: board.frame.minY - src.frame.minY)
            } else {
                shift = CGPoint(x: board.frame.midX - bounds.midX,
                                y: board.frame.midY - bounds.midY)
            }
        }
        // A plain layer selected means "put it on this": the copy centres on the
        // selection and stacks directly above it. Identical bounds mean the copy
        // IS the selection (that's what duplicate does), so the visible nudge
        // stays — a paste-in-place would vanish into its original.
        var stackTarget: String?
        if targetOrigin == nil, targetBoard == nil, selection.count == 1,
           let sel = selection.first, let selLayer = p.layer(sel), !selLayer.isArtboard {
            stackTarget = sel
            if let o = p.absoluteOrigin(of: sel) {
                let r = CGRect(origin: o, size: selLayer.frame.size)
                let same = abs(r.midX - bounds.midX) < 0.5 && abs(r.midY - bounds.midY) < 0.5
                if !same {
                    shift = CGPoint(x: r.midX - bounds.midX, y: r.midY - bounds.midY)
                }
            }
        }
        let fresh = layers.map { l -> Layer in
            var c = l.withNewIDs()
            c.frame.origin = CGPoint(x: c.frame.minX + shift.x, y: c.frame.minY + shift.y)
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
        if let board = targetBoard {
            // Into the CHOSEN board, not whichever one happens to contain the
            // centre — the point of selecting it first.
            _ = p.reparent(fresh.map(\.id), into: board.id, at: p.children(of: board.id).count)
        } else if let stack = stackTarget {
            // Directly above the selected layer, in its container.
            if let parent = p.ancestors(of: stack).last {
                let index = (p.children(of: parent).firstIndex { $0.id == stack } ?? 0) + 1
                _ = p.reparent(fresh.map(\.id), into: parent, at: index)
            } else {
                let moved = Array(p.layers.suffix(fresh.count))
                p.layers.removeLast(fresh.count)
                let at = (p.layers.firstIndex { $0.id == stack } ?? p.layers.count - 1) + 1
                p.layers.insert(contentsOf: moved, at: min(at, p.layers.count))
            }
        } else {
            for l in fresh { p.adoptIntoArtboard(l.id) }
        }
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

    /// ⇧⌘V: the copy lands with its top-left exactly on the selection's top-left.
    func pasteAtSelection() {
        guard let p = page, !selection.isEmpty else { paste(); return }
        var r = CGRect.null
        for id in selection {
            guard let l = p.layer(id), let o = p.absoluteOrigin(of: id) else { continue }
            r = r.union(CGRect(origin: o, size: l.frame.size))
        }
        guard !r.isNull else { paste(); return }
        paste(at: r.origin)
    }

    func duplicateSelection() {
        copySelection()
        paste()
        undoManager.setActionName("Duplicate")
    }

    func selectAll() {
        guard let page else { return }
        // Artboards are only selected deliberately — their canvas label or the
        // layer list. ⌘A gathers the ARTWORK: each board's children plus loose
        // layers. Sweeping the board itself into the selection made it the target
        // of whatever came next (paste, delete) without anyone choosing that.
        var ids: [String] = []
        for l in page.layers {
            if l.isArtboard {
                if case .group(let kids) = l.kind { ids.append(contentsOf: kids.map(\.id)) }
            } else {
                ids.append(l.id)
            }
        }
        selection = Set(ids)
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

    /// The insert menu and the chat create layers the same way — Page.add is the
    /// single implementation, so an artboard made by asking for one is identical to
    /// an artboard made from the menu.
    /// Puts a new shape exactly where it was drawn, then hands the pointer back.
    ///
    /// The key arms the tool and the drag says where and how big, which is what
    /// every drawing app has done since Fireworks and what dropping one in the
    /// middle of the canvas can't be: every shape used to start life needing to be
    /// moved somewhere else.
    ///
    /// Coordinates are page space. Adoption converts them if the shape lands on an
    /// artboard, so a rectangle drawn on a board keeps the corner it was drawn at.
    @discardableResult
    func placeShape(_ tool: Tool, in frame: CGRect) -> String? {
        var spec = AddSpec()
        spec.kind = tool.kind
        spec.x = Double(frame.minX)
        spec.y = Double(frame.minY)
        // A click with no drag takes the shape's own default size rather than a
        // number repeated here, so there stays one answer to how big a new
        // rectangle is. Clicking is how you place text; dragging is how you draw.
        if frame.width >= 2, frame.height >= 2 {
            spec.width = Double(frame.width)
            spec.height = Double(frame.height)
        }
        var made: String?
        mutatePage("Insert \(tool.title)") { made = $0.add(spec) }
        if let made { selection = [made] }
        // Text arrives ready to be typed into. Placing a box that says "Type
        // something" and making the user find it again is the friction this whole
        // change is about.
        if tool == .text { pendingTextEdit = made }
        // Back to the pointer, so the next click selects rather than drawing a
        // second one. Sketch does this and the muscle memory is universal.
        self.tool = .select
        return made
    }

    private func insert(_ kind: String, _ actionName: String) {
        var spec = AddSpec()
        spec.kind = kind
        var made: String?
        mutatePage(actionName) { made = $0.add(spec) }
        if let made { selection = [made] }
    }

    /// Refits the selected paths with fewer points. Reports what it saved, because
    /// "Simplify" that silently did nothing is indistinguishable from one that ruined
    /// the shape until you look closely.
    @discardableResult
    func simplifySelection(detail: Double) -> String {
        guard !selection.isEmpty else { return "Nothing selected." }
        var report = ""
        let ids = selection
        mutatePage("Simplify") { page in
            // An empty query inherits the selection, which is what the menu wants.
            report = page.run([.simplify(LayerQuery(), tolerance: nil, detail: detail)],
                              selection: ids).report
        }
        return report
    }

    func insertArtboard()  { insert("artboard", "Insert Artboard") }

    /// Insert ▸ Artboard from Selection: a board the exact size of what's selected,
    /// which then owns it — the way a placed image becomes an artboard.
    func insertArtboardFromSelection() {
        let ids = Array(selection)
        guard !ids.isEmpty else { status = "Select something to build the artboard around"; return }
        var made: String?
        mutatePage("Artboard from Selection") { made = $0.artboardAround(ids) }
        if let made { selection = [made] }
        else { status = "Artboard from Selection needs top-level layers" }
    }
    func insertRectangle() { insert("rect", "Insert Rectangle") }
    func insertOval()      { insert("ellipse", "Insert Oval") }
    func insertStar()      { insert("star", "Insert Star") }
    func insertPolygon()   { insert("polygon", "Insert Polygon") }

    /// Re-cooks a star or polygon from new parameters, in place.
    func setAutoShape(_ id: String, sides: Int? = nil, innerRatio: CGFloat? = nil) {
        edit(id, actionName: "Change Shape") { l in
            guard var a = l.autoShape else { return }
            if let sides { a.sides = max(3, min(60, sides)) }
            if let innerRatio { a.innerRatio = min(0.95, max(0.05, innerRatio)) }
            l.autoShape = a
            l.regenerateAutoShape()
        }
    }
    func insertText()      { insert("text", "Insert Text") }

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

    /// MCP ▸ place_image: image bytes land as a bitmap layer, optionally inside a
    /// named artboard — so an agent can generate a piece and drop it exactly where
    /// the comic panel needs it, without a drag through the Finder.
    func placeImageFromAPI(_ data: Data, name: String, artboardNamed: String?,
                           x: Double?, y: Double?, width: Double?, height: Double?) -> String {
        guard let src = source else { return "No document open." }
        guard let loaded = BitmapImage.load(data) else { return "That file isn't a readable image." }

        var parentID: String?
        var parentFrame: CGRect?
        if let wanted = artboardNamed, !wanted.isEmpty {
            guard let page else { return "No page." }
            let boards = page.layers.filter(\.isArtboard)
            guard let board = boards.first(where: { $0.name == wanted })
                ?? boards.first(where: { $0.name.lowercased() == wanted.lowercased() }) else {
                let names = boards.map(\.name).joined(separator: ", ")
                return "No artboard named “\(wanted)”. Artboards here: \(names.isEmpty ? "none" : names)"
            }
            parentID = board.id
            parentFrame = board.frame
        }

        // Natural size, capped to fit where it lands; explicit width/height win,
        // and giving just one keeps the aspect.
        let display = loaded.displaySize
        let size: CGSize
        if let width, let height {
            size = CGSize(width: width, height: height)
        } else if let width {
            size = CGSize(width: width, height: width * display.height / max(1, display.width))
        } else if let height {
            size = CGSize(width: height * display.width / max(1, display.height), height: height)
        } else {
            let cap = parentFrame.map { min($0.width, $0.height) } ?? 800
            let scale = min(1, cap / max(display.width, display.height))
            size = CGSize(width: display.width * scale, height: display.height * scale)
        }

        // Coordinates are relative to the artboard when one is named, matching
        // how run_commands positions into a parent.
        let origin: CGPoint
        if let pf = parentFrame {
            origin = CGPoint(x: x.map { CGFloat($0) } ?? (pf.width - size.width) / 2,
                             y: y.map { CGFloat($0) } ?? (pf.height - size.height) / 2)
        } else {
            let fallback = insertionPoint(size)
            origin = CGPoint(x: x.map { CGFloat($0) } ?? fallback.x,
                             y: y.map { CGFloat($0) } ?? fallback.y)
        }

        let key = "images/\(Zip.crc32(data))-\(data.count).png"
        source = src.adding(image: data, key: key)
        var l = Layer(kind: .bitmap(imageRef: key))
        l.name = name.isEmpty ? "Image" : name
        l.frame = CGRect(origin: origin, size: size)
        let pid = parentID
        mutatePage("Place Image") { p in
            p.insertLayer(l, parent: pid, index: p.children(of: pid).count)
        }
        selection = [l.id]
        let place = artboardNamed.map { " in “\($0)”" } ?? ""
        return "Placed “\(l.name)” (\(Int(size.width))×\(Int(size.height)))\(place)."
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
            l.curveModes = vp.points.map(\.mode)
            l.frame = CGRect(origin: origin, size: box.size)
        }
    }

    /// Arrow-key nudge. Shift moves by 10 the way every design tool does.
    /// Turns a movement seen on the page into the movement to apply to a frame,
    /// which lives in its parent's space. Inside a flipped group "+x" points left
    /// and inside a rotated one it points off at an angle; without this, pressing
    /// right or dragging right moved the art the wrong way.
    static func inParentSpace(_ delta: CGPoint, of id: String, on page: Page) -> CGPoint {
        var toPage = CGAffineTransform.identity
        for ancestor in page.ancestors(of: id).reversed() {
            guard let a = page.layer(ancestor) else { continue }
            toPage = toPage.concatenating(Compose.transform(a))
        }
        guard !toPage.isIdentity else { return delta }
        let inverse = toPage.inverted()
        // A direction, not a position: the translation has no part in it.
        let origin = CGPoint.zero.applying(inverse)
        let moved = delta.applying(inverse)
        return CGPoint(x: moved.x - origin.x, y: moved.y - origin.y)
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        guard !selection.isEmpty, let page else { return }
        // A frame lives in its PARENT's space. Inside a flipped group "+x" points
        // left on screen, and inside a rotated one it points off at an angle — so
        // the arrow you pressed is mapped through the containers before it is
        // applied. Press right, the art goes right, whatever it happens to sit in.
        var deltas: [String: CGPoint] = [:]
        for id in selection {
            deltas[id] = Self.inParentSpace(CGPoint(x: dx, y: dy), of: id, on: page)
        }
        edit(Array(selection), actionName: "Nudge") { l in
            let d = deltas[l.id] ?? CGPoint(x: dx, y: dy)
            l.frame.origin = CGPoint(x: l.frame.minX + d.x, y: l.frame.minY + d.y)
        }
    }

    /// Everything the marquee touched.
    func selectAll(in rect: CGRect, on page: Page, extend: Bool) {
        let hits = page.marqueeHits(rect)
        selection = extend ? selection.union(hits) : hits
    }

    /// How many undo steps have been registered. Only tests read it — asking "did that
    /// drag make one step or ninety" any other way means reasoning about UndoManager's
    /// run-loop grouping, which a synchronous test can't reproduce.
    private(set) var undoStepsRegistered = 0

    private func registerUndo(restore: [String: Layer], redo: RedoBox,
                              pageIndex idx: Int, actionName: String) {
        undoStepsRegistered += 1
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.replaceLayers(restore, pageIndex: idx)
                // Registering during undo is what makes redo work. Reading the box
                // here rather than at registration is what lets a coalesced gesture
                // finish before its redo state is fixed.
                store.registerUndo(restore: redo.layers, redo: RedoBox(restore),
                                   pageIndex: idx, actionName: actionName)
                store.isDirty = true
                store.endCoalescing()
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

    // MARK: - Autosave

    /// Sketch-style recovery: while a document is dirty, a snapshot of it sits in
    /// Application Support, and a launch that finds snapshots reopens them as dirty
    /// documents. Quit without saving, crash, or get killed by a test script — the
    /// work comes back. A clean save or an explicit Don't Save deletes the snapshot,
    /// so recovery never argues with what the user decided.
    static var recoveryDirOverride: URL?
    static var recoveryDir: URL {
        recoveryDirOverride ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Accomplice/Recovery", isDirectory: true)
    }

    /// All recovery IO goes through one serial queue, so "write the snapshot" and
    /// "the user saved, delete it" can never land out of order.
    private static let recoveryQueue = DispatchQueue(label: "com.accomplice.autosave", qos: .utility)
    static func flushRecoveryQueueForTesting() { recoveryQueue.sync {} }

    private let autosaveID = UUID().uuidString
    private var autosaveTask: Task<Void, Never>?
    /// Seconds of quiet after the last edit before a snapshot is written.
    static var autosaveDelay: TimeInterval = 3

    struct Recovery {
        let snapshot: URL
        let sidecar: URL
        let original: URL?
    }

    /// Snapshots left behind by documents that never got a clean save.
    static func pendingRecoveries() -> [Recovery] {
        guard let entries = try? FileManager.default
            .contentsOfDirectory(at: recoveryDir, includingPropertiesForKeys: nil) else { return [] }
        return entries.filter { $0.lastPathComponent.hasSuffix(".acmplc.png") }.map { snap in
            let sidecar = recoveryDir.appendingPathComponent(
                snap.lastPathComponent.replacingOccurrences(of: ".acmplc.png", with: ".json"))
            var original: URL?
            if let d = try? Data(contentsOf: sidecar),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let p = j["original"] as? String {
                original = URL(fileURLWithPath: p)
            }
            return Recovery(snapshot: snap, sidecar: sidecar, original: original)
        }
    }

    /// Loads a snapshot into this store as unsaved work on the original file, then
    /// removes it — the store immediately re-snapshots under its own id, so the
    /// safety net never has a gap.
    func restoreFromRecovery(_ rec: Recovery) {
        defer {
            Self.recoveryQueue.async {
                try? FileManager.default.removeItem(at: rec.snapshot)
                try? FileManager.default.removeItem(at: rec.sidecar)
            }
        }
        guard let (doc, images) = try? AcmplcFile.read(url: rec.snapshot) else { return }
        adopt(doc, images: images)
        url = rec.original
        isDirty = true
        // Straight away, not on the debounce: the old snapshot is deleted below, and
        // the net must not have a three-second hole in it.
        autosaveNow()
        status = "Restored unsaved work"
            + (rec.original.map { " on \($0.lastPathComponent)" } ?? "")
    }

    private func scheduleAutosave() {
        // A THROTTLE, not a debounce. Cancelling and re-arming on every edit meant
        // continuous work pushed the snapshot forever into the future — minutes of
        // editing with the net never once touching the ground.
        guard autosaveTask == nil else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autosaveDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.autosaveTask = nil
            self?.autosaveNow()
        }
    }

    /// Removes a snapshot that will never be restored.
    static func discardRecovery(_ rec: Recovery) {
        recoveryQueue.async {
            try? FileManager.default.removeItem(at: rec.snapshot)
            try? FileManager.default.removeItem(at: rec.sidecar)
        }
    }

    /// Writes the recovery snapshot. Internal (not private) so a test can skip the
    /// debounce timer.
    func autosaveNow() {
        guard isDirty, let src = source else { return }
        let id = autosaveID
        let original = url
        var opts = AcmplcFile.Options()
        opts.coverPage = coverPage
        let options = opts
        Self.recoveryQueue.async {
            let dir = Self.recoveryDir
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // Full document, same as a real save — untouched lazy pages included.
                let doc = src.fullDocument()
                let data = try AcmplcFile.write(document: doc, images: src.images, options: options)
                try data.write(to: dir.appendingPathComponent("\(id).acmplc.png"), options: .atomic)
                let side = try JSONSerialization.data(withJSONObject: ["original": original?.path as Any])
                try side.write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
            } catch {
                // Best-effort: a failed snapshot must never interrupt the edit that
                // triggered it. The next edit tries again.
            }
        }
    }

    private func clearRecovery() {
        autosaveTask?.cancel()
        autosaveTask = nil
        let id = autosaveID
        Self.recoveryQueue.async {
            let dir = Self.recoveryDir
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).acmplc.png"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
        }
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
        // Offer the base name only, and let the panel own the extension. macOS
        // otherwise treats ".png" as the whole extension and highlights
        // "Untitled.acmplc" — so typing a name naturally throws away the ".acmplc"
        // that decides which app opens the file.
        panel.nameFieldStringValue = AcmplcFile.baseName(url?.lastPathComponent ?? "Untitled")
        // Deliberately NO allowedContentTypes. Declaring our type makes macOS resolve
        // the compound extension as plain "png" and push ".acmplc" back into the name
        // field — so it highlights "Untitled.acmplc" again, which is the thing being
        // fixed. Left alone, the field holds just the name, and normalisedName puts the
        // whole extension on afterwards.
        panel.nameFieldLabel = "Save As:"
        panel.message = "Saved as an Accomplice document (.acmplc.png)"
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, var out = panel.url else { completion?(false); return }
        // Keep the compound extension whatever was typed. The rule lives in Core so
        // it can be tested; getting it wrong doesn't lose data, but it does lose the
        // file to Preview.
        out = out.deletingLastPathComponent()
            .appendingPathComponent(AcmplcFile.normalisedName(out.lastPathComponent))
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
            if outcome.ok {
                self.isDirty = false
                RecentDocuments.shared.note(url)
            } else {
                NSSound.beep()
            }
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
        let suffix = scale == 1 ? "" : "@\(Int(scale))x"

        // One thing gets a SAVE panel: you can name it before it lands, and
        // clicking a file in the list adopts that name, the way every other save
        // does. A folder chooser can do neither — it exports whatever name the
        // layer happened to have. Several at once still pick a folder, since
        // there is no single name to type.
        var dir: URL
        var singleName: String?
        if targets.count == 1 {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            panel.message = "Export \(what) as \(format.title)"
            panel.nameFieldLabel = "Export As:"
            panel.nameFieldStringValue = "\(slug(targets[0].page.name))\(suffix).\(format.rawValue)"
            if let type = UTType(filenameExtension: format.rawValue) {
                panel.allowedContentTypes = [type]
            }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            dir = url.deletingLastPathComponent()
            singleName = url.lastPathComponent
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.message = "Export \(targets.count) \(what) as \(format.title)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            dir = url
        }

        let imgs = images
        var written = 0
        var rotatedWarnings = 0
        for t in targets {
            if t.rotatedAncestor { rotatedWarnings += 1 }
            let base = slug(t.page.name)
            let file = singleName.map { dir.appendingPathComponent($0) }
                ?? dir.appendingPathComponent("\(base)\(suffix).\(format.rawValue)")
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
    let isLocked: Bool
    let children: [LayerNode]?

    init(_ l: Layer) {
        id = l.id
        isVisible = l.isVisible
        isLocked = l.isLocked
        switch l.kind {
        // An empty container is still a container. `nil` here means "a leaf, nothing can
        // go inside it", and collapsing empty to nil made an empty artboard refuse every
        // drop — so there was no way to get the FIRST layer into one, which is the only
        // time you need to.
        case .group(let k):
            kindLabel = l.isArtboard ? "Artboard" : "Group"
            systemImage = l.isArtboard ? "rectangle.dashed" : "folder"
            children = k.map(LayerNode.init)
        case .shapeGroup(let k, _):
            kindLabel = "Combined"; systemImage = "square.on.circle"
            children = k.map(LayerNode.init)
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
