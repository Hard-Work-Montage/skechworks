import XCTest
import CoreGraphics
import SkechworksCore
@testable import Skechworks

/// Tests for the layer between the model and the UI.
///
/// This target exists because that layer had none. DocumentStore and the canvas are
/// about 2,300 lines and nearly every bug found by using the app has been in them or
/// at their boundary: edits discarded by the change detector, a resize mixing
/// coordinate spaces, selection broken by attaching a drag handler.
@MainActor
final class DocumentStoreTests: XCTestCase {

    /// A store holding a document with an artboard, a group, and a photo inside it.
    private func loaded() -> (DocumentStore, group: String, photo: String) {
        var photo = Layer(kind: .bitmap(imageRef: "p.png"))
        photo.name = "Photo"
        photo.frame = CGRect(x: 50, y: 50, width: 200, height: 200)

        var group = Layer(kind: .group([photo]))
        group.name = "Group"
        group.frame = CGRect(x: 100, y: 100, width: 300, height: 300)

        var art = Layer(kind: .group([group]))
        art.name = "Frame"
        art.isArtboard = true
        art.frame = CGRect(x: 0, y: 0, width: 600, height: 600)

        var page = Page(name: "Page 1")
        page.layers = [art]
        var doc = Document()
        doc.pages = [page]

        let store = DocumentStore()
        store.adopt(doc, images: [:])
        return (store, group.id, photo.id)
    }

    /// A layer's frame lives in its PARENT's space, so inside a flipped group
    /// "+x" points left on screen. Pressing the right arrow has to move the art
    /// right whatever the container is doing.
    func testNudgingInsideAFlippedGroupGoesTheWayYouPressed() {
        var child = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 50, height: 50),
                                             transform: nil), closed: true))
        child.name = "Child"
        child.frame = CGRect(x: 10, y: 10, width: 50, height: 50)
        var group = Layer(kind: .group([child]))
        group.name = "Flipped"
        group.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        group.flipH = true

        var page = Page(name: "Page 1")
        page.layers = [group]
        var doc = Document()
        doc.pages = [page]
        let store = DocumentStore()
        store.adopt(doc, images: [:])

        func onScreen() -> CGPoint {
            let g = store.page!.layers[0]
            guard case .group(let kids) = g.kind else { return .zero }
            return CGPoint.zero.applying(Compose.transform(kids[0])
                .concatenating(Compose.transform(g)))
        }
        let before = onScreen()
        store.selection = [child.id]
        store.nudge(dx: 10, dy: 0)
        let after = onScreen()
        XCTAssertEqual(after.x, before.x + 10, accuracy: 0.01,
                       "right arrow moves the art right, even inside a flipped group")
        XCTAssertEqual(after.y, before.y, accuracy: 0.01)
    }

    func testPasteWithALayerSelectedStacksTheCopyOnIt() {
        var a = Layer(kind: .bitmap(imageRef: "a.png"))
        a.name = "Source"
        a.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        var b = Layer(kind: .bitmap(imageRef: "b.png"))
        b.name = "Target"
        b.frame = CGRect(x: 300, y: 300, width: 100, height: 100)
        var page = Page(name: "Page 1")
        page.layers = [a, b]
        var doc = Document()
        doc.pages = [page]
        let store = DocumentStore()
        store.adopt(doc, images: [:])

        store.selection = [a.id]
        store.copySelection()
        store.selection = [b.id]
        store.paste()

        let layers = store.page!.layers
        XCTAssertEqual(layers.count, 3)
        let pasted = layers[2]
        XCTAssertEqual(layers[1].id, b.id, "the copy sits directly above the target")
        XCTAssertEqual(pasted.frame.midX, 350, accuracy: 0.6, "centred on the target")
        XCTAssertEqual(pasted.frame.midY, 350, accuracy: 0.6)
    }

    func testPixelSelectCopiesTheBoxAndPastesOverIt() {
        // A real 100×100 white image behind a 200×200 frame: layer units are 2×
        // the pixels, which is exactly the scaling copy has to get right.
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let png = Renderer.png(ctx.makeImage()!)!

        var photo = Layer(kind: .bitmap(imageRef: "px.png"))
        photo.name = "Photo"
        photo.frame = CGRect(x: 40, y: 40, width: 200, height: 200)
        var page = Page(name: "Page 1")
        page.layers = [photo]
        var doc = Document()
        doc.pages = [page]
        let store = DocumentStore()
        store.adopt(doc, images: ["px.png": png])

        store.enterPixelSelect(photo.id)
        XCTAssertEqual(store.pixelSelectID, photo.id)
        store.pixelSelectRect = CGRect(x: 20, y: 20, width: 80, height: 60)

        store.copySelection()
        let copied = NSPasteboard.general.data(forType: .png)
        XCTAssertNotNil(copied, "the boxed pixels should land on the pasteboard")
        let cg = BitmapImage.load(copied!)!.image
        XCTAssertEqual(cg.width, 40, "80 layer units at half scale is 40 pixels")
        XCTAssertEqual(cg.height, 30)

        store.paste()
        let pasted = store.page!.layers.first { $0.name == "Pasted pixels" }
        XCTAssertNotNil(pasted, "paste in pixel mode should add a bitmap over the box")
        XCTAssertEqual(pasted!.frame, CGRect(x: 60, y: 60, width: 80, height: 60),
                       "the paste lands exactly on the box")
    }

    func testMarkingAMaskSticksEvenWhenNothingMoves() {
        let (store, _, photo) = loaded()
        store.selection = [photo]
        store.toggleMask()
        XCTAssertTrue(store.page?.layer(photo)?.hasClippingMask == true,
                      "the change detector discarded an edit that moved no geometry")
    }

    func testResizingALayerInsideAGroupKeepsTheAnchoredCorner() {
        let (store, _, photo) = loaded()
        store.selection = [photo]
        let anchor = store.page!.absoluteOrigin(of: photo)!

        store.beginResize()
        store.endResize(scale: CGSize(width: 2, height: 2), anchor: anchor)

        XCTAssertEqual(store.page!.absoluteOrigin(of: photo)!.x, anchor.x, accuracy: 0.01)
        XCTAssertEqual(store.page!.absoluteOrigin(of: photo)!.y, anchor.y, accuracy: 0.01)
        XCTAssertEqual(store.page!.layer(photo)!.frame.width, 400, accuracy: 0.01)
    }

    func testUndoRestoresWhatAnEditChanged() {
        let (store, _, photo) = loaded()
        store.selection = [photo]
        let before = store.page!.layer(photo)!.frame

        store.nudge(dx: 10, dy: 0)
        XCTAssertEqual(store.page!.layer(photo)!.frame.minX, before.minX + 10, accuracy: 0.01)

        store.undo()
        XCTAssertEqual(store.page!.layer(photo)!.frame.minX, before.minX, accuracy: 0.01)
    }

    func testMovingALayerIntoAnArtboardLeavesItWhereItWas() {
        let (store, _, photo) = loaded()
        let art = store.page!.layers[0].id
        let was = store.page!.absoluteOrigin(of: photo)!

        XCTAssertTrue(store.moveLayers([photo], into: art, at: 0))
        XCTAssertEqual(store.page!.absoluteOrigin(of: photo)!.x, was.x, accuracy: 0.01)
        XCTAssertEqual(store.page!.absoluteOrigin(of: photo)!.y, was.y, accuracy: 0.01)
    }

    func testAddingAShadowRegistersAsAnEdit() {
        let (store, group, _) = loaded()
        store.addShadow(group)
        XCTAssertEqual(store.page?.layer(group)?.style.shadows.count, 1)
    }

    func testTheConversationBelongsToTheDocument() {
        // It was a @StateObject inside ChatPanel, which SwiftUI destroys with the view,
        // so hiding chat threw the conversation away. Owning it here is what makes it
        // outlive the panel.
        let (store, _, _) = loaded()
        store.chat.messages.append(ChatMessage(role: .user, text: "make the coin bigger"))
        XCTAssertEqual(store.chat.messages.count, 1)

        // The same store hands back the same session however many times it's asked.
        XCTAssertTrue(store.chat === store.chat)
        XCTAssertEqual(store.chat.messages.first?.text, "make the coin bigger")
    }

    func testEachDocumentHasItsOwnConversation() {
        let (a, _, _) = loaded()
        let (b, _, _) = loaded()
        a.chat.messages.append(ChatMessage(role: .user, text: "only in a"))
        XCTAssertEqual(a.chat.messages.count, 1)
        XCTAssertTrue(b.chat.messages.isEmpty, "windows must not share a conversation")
    }

    func testARotateDragIsOneUndoStepFromWhereItStarted() {
        // The canvas reports the whole turn each frame, not an increment. Committing
        // against the live value instead of the starting one would compound it.
        let (store, _, photo) = loaded()
        store.selection = [photo]
        store.beginRotate()

        let centre = CGPoint(x: store.page!.absoluteOrigin(of: photo)!.x + 100,
                             y: store.page!.absoluteOrigin(of: photo)!.y + 100)
        store.endRotate(degrees: 1, centre: centre)
        XCTAssertEqual(store.page!.layer(photo)!.rotation, 1, accuracy: 0.001)

        store.undo()
        XCTAssertEqual(store.page!.layer(photo)!.rotation, 0, accuracy: 0.001)
    }

    func testRotatingASingleLayerLeavesItWhereItIs() {
        let (store, _, photo) = loaded()
        store.selection = [photo]
        let was = store.page!.absoluteOrigin(of: photo)!
        store.beginRotate()
        store.endRotate(degrees: 30, centre: CGPoint(x: was.x + 100, y: was.y + 100))

        XCTAssertEqual(store.page!.absoluteOrigin(of: photo)!.x, was.x, accuracy: 0.01)
        XCTAssertEqual(store.page!.absoluteOrigin(of: photo)!.y, was.y, accuracy: 0.01)
    }

    func testSavingToAPlainNameStillProducesAnSkechworksDocument() throws {
        // The save panel now offers just the base name, so the URL that comes back has
        // no extension at all. What lands on disk still has to be a .sw.png that
        // opens with every layer.
        let (store, _, photo) = loaded()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sw-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let typed = dir.appendingPathComponent("Coin")           // exactly what's typed
        let final = typed.deletingLastPathComponent()
            .appendingPathComponent(SkechworksFile.normalisedName(typed.lastPathComponent))
        XCTAssertEqual(final.lastPathComponent, "Coin.sw.png")

        store.url = final
        let done = expectation(description: "written")
        store.save { ok in XCTAssertTrue(ok); done.fulfill() }
        wait(for: [done], timeout: 10)

        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        let (back, _) = try SkechworksFile.read(url: final)
        XCTAssertEqual(back.pages.count, 1)
        XCTAssertNotNil(back.pages[0].layer(photo), "the photo should have survived the save")
    }

    /// A shape drawn over an artboard has to land inside it — and undo has to be able
    /// to reach it there. Removal used to search only the top level, so an undo of a
    /// drawing that had been adopted would have quietly done nothing.
    func testADrawnShapeLandsInTheArtboardAndUndoTakesItBack() {
        let (store, _, _) = loaded()
        guard let board = store.page?.layers.first?.id else { return XCTFail("no artboard") }

        var drawn = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                             transform: nil), closed: true))
        drawn.name = "Drawn"
        drawn.frame = CGRect(x: 200, y: 200, width: 40, height: 40)
        store.addLayer(drawn)

        XCTAssertEqual(store.page?.ancestors(of: drawn.id), [board])
        XCTAssertEqual(store.page?.layers.count, 1, "it should not also be a sibling of the artboard")
        // Adopted, not moved: still at 200,200 on the page.
        XCTAssertEqual(store.page?.absoluteOrigin(of: drawn.id), CGPoint(x: 200, y: 200))

        store.undo()
        XCTAssertNil(store.page?.layer(drawn.id), "undo left the drawing inside the artboard")
    }

    /// Copying out of an artboard and pasting has to put it back in the same place.
    /// Frames are relative to their container, so a clipboard holding one straight
    /// threw the paste by the artboard's offset.
    func testPastingSomethingCopiedFromAnArtboardLandsBackInIt() {
        let (store, _, photo) = loaded()
        guard let board = store.page?.layers.first?.id else { return XCTFail("no artboard") }
        let before = store.page?.absoluteOrigin(of: photo)

        store.selection = [photo]
        store.copySelection()
        // Deselect first: paste with a layer selected stacks the copy on it (its
        // own contract, tested separately). This test is about the coordinates.
        store.selection = []
        store.paste()

        guard let pasted = store.selection.first, pasted != photo else {
            return XCTFail("nothing was pasted")
        }
        XCTAssertEqual(store.page?.ancestors(of: pasted).last, board)
        // Nudged by 20 so a paste-in-place is visible, and no further.
        XCTAssertEqual(store.page?.absoluteOrigin(of: pasted),
                       before.map { CGPoint(x: $0.x + 20, y: $0.y + 20) })
    }

    /// The layer list refuses a drop onto anything it thinks is a leaf, and it read
    /// "leaf" off a nil child list — which an EMPTY group reported. So an empty artboard
    /// took no drops at all, and getting the first layer into one is the only time you
    /// need to. Everything after that worked, which is why it read as random.
    func testAnEmptyArtboardStillCountsAsSomethingYouCanDropInto() {
        var art = Layer(kind: .group([]))
        art.name = "Frame"
        art.isArtboard = true
        art.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        var stray = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                             transform: nil), closed: true))
        stray.name = "Path"
        stray.frame = CGRect(x: 900, y: 900, width: 40, height: 40)

        var page = Page(name: "Page 1")
        page.layers = [art, stray]
        var doc = Document()
        doc.pages = [page]
        let store = DocumentStore()
        store.adopt(doc, images: [:])

        // The list is built from these, and LayerItem.isContainer is `children != nil`.
        let tree = (store.page?.layers ?? []).map(LayerNode.init)
        XCTAssertNotNil(tree.first { $0.name == "Frame" }?.children,
                        "an empty artboard has to read as a container, or it takes no drops")

        XCTAssertTrue(store.moveLayers([stray.id], into: art.id, at: 0))
        XCTAssertEqual(store.page?.ancestors(of: stray.id), [art.id])
    }

    func testEveryMenuShortcutResolvesInTheRegistry() {
        // The menus bind by id. A typo would be a menu item with no shortcut at all,
        // which is invisible until someone reaches for the key.
        for id in ["new", "open", "close", "save", "undo", "redo", "cut", "copy", "paste",
                   "duplicate", "selectAll", "zoomIn", "zoomOut", "actualSize", "zoomFit",
                   "zoomSelection", "insertArtboard", "insertRect", "insertOval",
                   "insertText", "vector", "select", "bringForward", "bringToFront",
                   "sendBackward", "sendToBack", "group", "ungroup", "mask", "ignoreMask",
                   "hide", "ask", "exportPage", "exportAll", "closeAll", "saveAs"] {
            XCTAssertFalse(Shortcuts[id].title.isEmpty, "\(id) missing from the registry")
        }
    }
}

/// The Open Recent menu.
@MainActor
final class RecentDocumentsTests: XCTestCase {

    private func scratch() -> UserDefaults {
        let suite = "skechworks.tests.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    func testAnOpenedFileIsRememberedImmediately() throws {
        // The old list lived in NSDocumentController, which writes when it likes —
        // anything but a clean quit lost the lot and the menu silently emptied.
        let defaults = scratch()
        let recents = RecentDocuments(defaults: defaults)

        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recent-\(UUID().uuidString).sw.png")
        try Data([0x89]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        recents.note(file)
        XCTAssertEqual(recents.urls.map(\.path), [file.path])

        // Already on disk, so a fresh instance sees it without anything being quit.
        XCTAssertEqual(RecentDocuments(defaults: defaults).urls.map(\.path), [file.path])
    }

    func testTheMostRecentComesFirstAndNothingRepeats() {
        var list = RecentDocuments.adding("/a", to: [])
        list = RecentDocuments.adding("/b", to: list)
        list = RecentDocuments.adding("/a", to: list)      // opened again
        XCTAssertEqual(list, ["/a", "/b"])
    }

    func testTheListIsCapped() {
        var list: [String] = []
        for i in 0..<40 { list = RecentDocuments.adding("/f\(i)", to: list) }
        XCTAssertEqual(list.count, RecentDocuments.limit)
        XCTAssertEqual(list.first, "/f39")
    }

    func testFilesThatHaveGoneAwayAreNotOffered() throws {
        let defaults = scratch()
        let gone = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gone-\(UUID().uuidString).sw.png")
        try Data([0x89]).write(to: gone)
        let recents = RecentDocuments(defaults: defaults)
        recents.note(gone)
        XCTAssertEqual(recents.urls.count, 1)

        try FileManager.default.removeItem(at: gone)
        recents.refresh()
        XCTAssertTrue(recents.urls.isEmpty, "a dead path is worse than a shorter menu")
    }
}

/// Page operations, which had no way to be reached at all until now.
@MainActor
final class PageTests: XCTestCase {

    private func store() -> DocumentStore {
        var doc = Document()
        doc.pages = [Page(name: "Page 1")]
        let s = DocumentStore()
        s.adopt(doc, images: [:])
        return s
    }

    func testAddingAPage() {
        let s = store()
        s.addPage()
        XCTAssertEqual(s.source?.pageCount, 2)
        XCTAssertEqual(s.pageIndex, 1, "the new page should be the one you're on")
    }

    func testRenamingAPage() {
        let s = store()
        s.renamePage(at: 0, to: "Coins")
        XCTAssertEqual(s.source?.pages.first?.name, "Coins")
        XCTAssertEqual(s.page?.name, "Coins")
    }

    /// NSUndoManager groups by event: everything registered in one run-loop turn
    /// undoes together. A person can't rename and delete in the same turn, but a test
    /// does exactly that, so the two are checked apart here and the combined sequence
    /// is covered by a UI test where the events are real.
    func testDeletingAPageCanBeUndone() {
        let s = store()
        s.addPage()
        XCTAssertEqual(s.source?.pageCount, 2)

        s.deletePage(at: 1)
        XCTAssertEqual(s.source?.pageCount, 1)

        s.undo()
        XCTAssertEqual(s.source?.pageCount, 2)
    }

    func testRenamingAPageCanBeUndone() {
        let s = store()
        s.renamePage(at: 0, to: "Coins")
        XCTAssertEqual(s.source?.pages.first?.name, "Coins")
        s.undo()
        XCTAssertEqual(s.source?.pages.first?.name, "Page 1")
    }

    func testTheLastPageCannotBeDeleted() {
        let s = store()
        s.deletePage(at: 0)
        XCTAssertEqual(s.source?.pageCount, 1, "a document has to have a page")
    }

    func testDuplicatingAPageGivesTheCopyItsOwnLayers() {
        let s = store()
        var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                         transform: nil), closed: true))
        l.name = "box"
        s.mutatePage("seed") { $0.layers = [l] }

        s.duplicatePage()
        XCTAssertEqual(s.source?.pageCount, 2)
        let original = s.source?.page(at: 0)?.layers.first?.id
        let copy = s.source?.page(at: 1)?.layers.first?.id
        XCTAssertNotNil(copy)
        XCTAssertNotEqual(original, copy, "shared ids would make edits hit both pages")
    }
}

extension PageTests {
    func testMovingAPageAndUndoingIt() {
        var doc = Document()
        doc.pages = ["One", "Two", "Three"].map { Page(name: $0) }
        let s = DocumentStore()
        s.adopt(doc, images: [:])

        XCTAssertTrue(s.movePage(from: 2, to: 0))
        XCTAssertEqual(s.source?.pages.map(\.name), ["Three", "One", "Two"])
        XCTAssertEqual(s.pageIndex, 0, "you should still be on the page you moved")

        s.undo()
        XCTAssertEqual(s.source?.pages.map(\.name), ["One", "Two", "Three"])
    }
}


// MARK: - Color

extension DocumentStoreTests {

    private func fillHex(_ store: DocumentStore, _ id: String) -> String? {
        guard case .color(let c)? = store.page?.layer(id)?.style.fills.first?.paint else { return nil }
        return c.hex
    }

    /// The system colour panel reports continuously while you drag around the wheel.
    /// One undo step per report would make ⌘Z walk back through every shade you passed
    /// through on the way to the one you wanted.
    func testDraggingThroughColorsIsOneUndoStep() {
        let (store, _, photo) = loaded()
        store.selection = [photo]
        store.addFill(photo)
        let steps = store.undoStepsRegistered

        for shade in stride(from: 0.1, through: 0.9, by: 0.1) {
            store.setFillColor(photo, at: 0, to: Color(r: shade, g: 0, b: 0, a: 1))
        }
        XCTAssertEqual(store.undoStepsRegistered, steps + 1,
                       "nine reports from the colour panel should be one undo step, not nine")
        XCTAssertEqual(fillHex(store, photo), "#e60000")

        // And redo has to land where the drag ENDED. The redo snapshot is captured
        // when the step opens, so unless the gesture keeps it current this comes back
        // #1a0000 — the first shade passed through on the way.
        store.undo()
        store.redo()
        XCTAssertEqual(fillHex(store, photo), "#e60000")
    }

    /// Two separate visits to the colour well are two edits, however quickly they
    /// follow each other — coalescing keys off the gesture, not off elapsed time.
    func testColoringADifferentLayerStartsANewUndoStep() {
        let (store, group, photo) = loaded()
        store.selection = [photo]
        store.addFill(photo)
        store.addFill(group)

        store.setFillColor(photo, at: 0, to: Color(r: 1, g: 0, b: 0, a: 1))
        let steps = store.undoStepsRegistered
        store.selection = [group]
        store.setFillColor(group, at: 0, to: Color(r: 0, g: 1, b: 0, a: 1))

        XCTAssertEqual(store.undoStepsRegistered, steps + 1,
                       "a different layer is a different gesture and needs its own step")
        XCTAssertEqual(fillHex(store, photo), "#ff0000")
        XCTAssertEqual(fillHex(store, group), "#00ff00")
    }

    /// The bug this guards is the seventh of its kind: the change detector saw only
    /// the FIRST fill's #rrggbb, so a second fill, an alpha, or a gradient stop could
    /// be changed and the edit thrown away as a no-op.
    func testTheSecondFillAndItsAlphaAreRealEdits() {
        let (store, _, photo) = loaded()
        store.selection = [photo]
        store.addFill(photo)
        store.addFill(photo)

        store.setFillColor(photo, at: 1, to: Color(r: 0, g: 0, b: 1, a: 1))
        guard case .color(let second)? = store.page?.layer(photo)?.style.fills[1].paint else {
            return XCTFail("second fill missing")
        }
        XCTAssertEqual(second.hex, "#0000ff")

        store.endCoalescing()
        store.setFillColor(photo, at: 0, to: Color(r: 0.5, g: 0.5, b: 0.5, a: 0.5))
        guard case .color(let faded)? = store.page?.layer(photo)?.style.fills[0].paint else {
            return XCTFail("first fill missing")
        }
        XCTAssertEqual(faded.a, 0.5, accuracy: 0.001, "changing only alpha is still an edit")
    }

    func testBorderColorAndWidthSurvive() {
        let (store, _, photo) = loaded()
        store.selection = [photo]
        store.addBorder(photo)
        store.setBorderColor(photo, at: 0, to: Color(r: 1, g: 0, b: 0, a: 1))
        store.setBorderThickness(photo, at: 0, to: 2.5)
        store.setBorderPosition(photo, at: 0, to: .inside)

        let b = store.page?.layer(photo)?.style.borders.first
        XCTAssertEqual(b?.color.hex, "#ff0000")
        XCTAssertEqual(b?.thickness ?? 0, 2.5, accuracy: 0.001,
                       "a fractional width was rounded away by the change detector")
        XCTAssertEqual(b?.position, .inside)
    }
}

// MARK: - Signing in

@MainActor
final class OAuthTests: XCTestCase {

    /// The worked example from RFC 7636 itself. If the challenge is computed wrongly
    /// the provider rejects the exchange, and the failure arrives as a flat "couldn't
    /// finish signing in" with nothing to point at — worth pinning to a known answer
    /// rather than to our own implementation.
    func testTheChallengeMatchesTheSpecsOwnExample() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(OAuthFlow.challenge(for: verifier),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    /// Base64 as URLs allow it. A "+" or "/" survives into a query string re-encoded,
    /// and the verifier no longer matches what was sent.
    func testEncodingIsUrlSafeAndUnpadded() {
        for _ in 0..<200 {
            let v = OAuthFlow.randomVerifier()
            XCTAssertFalse(v.contains("+"), v)
            XCTAssertFalse(v.contains("/"), v)
            XCTAssertFalse(v.contains("="), v)
            // RFC 7636 requires 43-128 characters; 32 random bytes gives 43.
            XCTAssertGreaterThanOrEqual(v.count, 43)
            XCTAssertLessThanOrEqual(v.count, 128)
        }
    }
}

// These landed inside OAuthTests at some point and stopped compiling: they
// lean on DocumentStoreTests' private loaded() fixture, which only an
// extension of that class in this file can reach.
extension DocumentStoreTests {

    func testSelectAllGathersTheArtworkNeverTheBoards() {
        // Artboards are selected deliberately — canvas label or layer list. ⌘A
        // sweeping the board into the selection made it the target of whatever came
        // next (paste into it, delete it) without anyone choosing that.
        var child = Layer(kind: .bitmap(imageRef: "c.png"))
        child.name = "Group"
        child.frame = CGRect(x: 10, y: 10, width: 50, height: 50)
        var art = Layer(kind: .group([child]))
        art.name = "Frame"
        art.isArtboard = true
        art.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        var loose = Layer(kind: .bitmap(imageRef: "loose.png"))
        loose.name = "Loose"
        loose.frame = CGRect(x: 700, y: 0, width: 100, height: 100)
        var page = Page(name: "Page 1")
        page.layers = [art, loose]
        var doc = Document()
        doc.pages = [page]
        let store = DocumentStore()
        store.adopt(doc, images: [:])

        store.selectAll()
        let names = store.selection.compactMap { store.page?.layer($0)?.name }.sorted()
        XCTAssertEqual(names, ["Group", "Loose"])   // the board's child + the loose layer
        XCTAssertFalse(store.selection.contains(where: { store.page?.layer($0)?.isArtboard == true }))
    }

    func testSavingALegacyNamedDocumentMovesItOntoTheNewExtension() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("Coin.acmplc.png")
        try Data("stale".utf8).write(to: old)

        let (store, _, _) = loaded()
        store.url = old
        let done = expectation(description: "written")
        store.save { ok in XCTAssertTrue(ok); done.fulfill() }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(store.url?.lastPathComponent, "Coin.sw.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Coin.sw.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "the old name does not linger beside the new one")
    }

    func testUnsavedWorkSurvivesThroughARecoverySnapshot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        DocumentStore.recoveryDirOverride = dir
        defer {
            DocumentStore.recoveryDirOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }

        // Dirty work snapshots…
        let (store, _, _) = loaded()
        store.isDirty = true
        store.autosaveNow()
        DocumentStore.flushRecoveryQueueForTesting()
        var found = DocumentStore.pendingRecoveries()
        XCTAssertEqual(found.count, 1, "a dirty document leaves a snapshot behind")

        // …and comes back as a dirty document with the same content.
        let fresh = DocumentStore()
        fresh.restoreFromRecovery(found[0])
        DocumentStore.flushRecoveryQueueForTesting()
        XCTAssertTrue(fresh.isDirty)
        XCTAssertEqual(fresh.page?.layers.first?.name, "Frame")
        XCTAssertEqual(DocumentStore.pendingRecoveries().count, 1,
                       "the restored document immediately re-snapshots under its own id")

        // A clean save-equivalent clears the net.
        found = DocumentStore.pendingRecoveries()
        fresh.isDirty = false
        DocumentStore.flushRecoveryQueueForTesting()
        XCTAssertEqual(DocumentStore.pendingRecoveries().count, 0)
    }

    func testDraggingOutOfAnArtboardEscapesToTheCanvasRoot() throws {
        let (store, _, photo) = loaded()   // photo lives in a group inside the artboard
        store.selection = [photo]
        let wasAbs = store.page!.absoluteOrigin(of: photo)!

        store.beginDrag(photo)
        store.endDrag(offset: CGSize(width: 2000, height: 0))   // far off the 600pt board

        let p = store.page!
        XCTAssertTrue(p.layers.contains { $0.id == photo },
                      "the layer sits at the canvas root now, not clipped inside the board")
        let nowAbs = p.absoluteOrigin(of: photo)!
        XCTAssertEqual(nowAbs.x, wasAbs.x + 2000, accuracy: 0.01)
        XCTAssertEqual(nowAbs.y, wasAbs.y, accuracy: 0.01)

        // Undo puts it back inside.
        store.undo()
        XCTAssertFalse(store.page!.layers.contains { $0.id == photo })
        XCTAssertNotNil(store.page!.layer(photo))
    }

    func testPasteAtSelectionLandsOnTheSelectionsTopLeft() throws {
        var a = Layer(kind: .bitmap(imageRef: "a.png"))
        a.name = "A"
        a.frame = CGRect(x: 40, y: 60, width: 100, height: 80)
        var b = Layer(kind: .bitmap(imageRef: "b.png"))
        b.name = "B"
        b.frame = CGRect(x: 500, y: 300, width: 50, height: 50)
        var page = Page(name: "P")
        page.layers = [a, b]
        var doc = Document()
        doc.pages = [page]
        let store = DocumentStore()
        store.adopt(doc, images: ["a.png": Data([1]), "b.png": Data([2])])

        store.selection = [a.id]
        store.copySelection()
        store.selection = [b.id]
        store.pasteAtSelection()

        let pasted = try XCTUnwrap(store.page?.layers.first { $0.id != a.id && $0.id != b.id },
                                   "paste appended a new layer")
        XCTAssertEqual(pasted.frame.origin, CGPoint(x: 500, y: 300),
                       "the copy's top-left sits exactly on the selection's top-left")
    }

    func testEveryVerifierIsDifferent() {
        let made = Set((0..<500).map { _ in OAuthFlow.randomVerifier() })
        XCTAssertEqual(made.count, 500, "a repeated verifier would defeat the point of PKCE")
    }

    /// Two colours of the same failure: no key at all, and a key for the wrong option.
    /// Each has to name the thing the user should go and do.
    func testUnconfiguredBackendsSayWhichSettingToChange() {
        XCTAssertTrue(ModelConnector.Failure.noKey.errorDescription?.contains("OpenRouter") == true)
        XCTAssertTrue(ModelConnector.Failure.notSignedIn.errorDescription?.contains("Skechworks") == true)
    }
}

extension DocumentStoreTests {

    /// Copying has to hand the rest of the machine something it can read.
    ///
    /// The pasteboard carried the native format and SVG-as-a-string, which is
    /// perfect for Skechworks and for a vector program and useless to everything
    /// else: paste into a browser, Mail or Preview and you got "that wasn't an
    /// image", because a string of SVG markup is exactly that.
    func testCopyingPutsABitmapOnThePasteboardForOtherApps() throws {
        var shape = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 80, height: 80),
                                             transform: nil), closed: true))
        shape.name = "Dot"
        shape.frame = CGRect(x: 10, y: 10, width: 80, height: 80)
        shape.style.fills = [Fill(paint: .color(Color(r: 1, g: 0, b: 0, a: 1)))]
        var page = Page(name: "P")
        page.layers = [shape]
        var doc = Document()
        doc.pages = [page]
        let store = DocumentStore()
        store.adopt(doc, images: [:])
        store.selection = [shape.id]

        NSPasteboard.general.clearContents()
        store.copySelection()

        let pb = NSPasteboard.general
        XCTAssertNotNil(pb.data(forType: DocumentStore.pasteboardType),
                        "Skechworks's own format should still be there, and first")
        XCTAssertNotNil(pb.string(forType: .string), "SVG should still be there for vector apps")

        let png = try XCTUnwrap(pb.data(forType: .png), "a browser needs a bitmap, not markup")
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "not a PNG")
        XCTAssertNotNil(pb.data(forType: .tiff), "some older Cocoa apps ask for nothing but TIFF")
    }

    /// Images arrive as bytes as often as they arrive as files — a screenshot
    /// shelf, a drag off a web page — and those used to be refused outright.
    func testAnImageDroppedAsBytesIsPlaced() throws {
        var doc = Document()
        doc.pages = [Page(name: "P")]
        let store = DocumentStore()
        store.adopt(doc, images: [:])
        store.source = DocumentSource.eager(doc, images: [:])

        let ctx = CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        let tiff = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .tiff, properties: [:])!

        store.acceptDroppedImage(tiff, name: "Screenshot 2026-08-07.tiff")
        let placed = try XCTUnwrap(store.page?.layers.first)
        XCTAssertEqual(placed.name, "Screenshot 2026-08-07", "the extension shouldn't stay in the name")
        guard case .bitmap(let ref) = placed.kind else { return XCTFail("not a bitmap") }
        // Stored as a PNG rather than filed under a .png name while holding TIFF.
        let bytes = try XCTUnwrap(store.images[ref])
        XCTAssertEqual(Array(bytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "should be normalised to PNG")
    }

    /// Copy an .svg in Finder, ⌘V on the canvas: the shapes land in the document
    /// you are working on. It used to OPEN the file instead, in this window,
    /// which threw away the document you had — an .svg counts as a document,
    /// so the paste took the open-a-document branch.
    func testAnSVGFilePastedAsAURLIsPlacedNotOpened() throws {
        var existing = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                                transform: nil), closed: true))
        existing.name = "Already here"
        existing.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        var page = Page(name: "Mine")
        page.layers = [existing]
        var doc = Document()
        doc.pages = [page]
        let store = DocumentStore()
        store.adopt(doc, images: [:])
        store.source = DocumentSource.eager(doc, images: [:])
        let mine = FileManager.default.temporaryDirectory.appendingPathComponent("mine.sw.png")
        store.url = mine

        let svg = FileManager.default.temporaryDirectory.appendingPathComponent("music.svg")
        try Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" \
        fill="none" stroke="currentColor" stroke-width="2">\
        <path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>
        """.utf8).write(to: svg)
        defer { try? FileManager.default.removeItem(at: svg) }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([svg as NSURL])
        store.paste()

        XCTAssertEqual(store.url, mine, "the document you had open should still be the one open")
        let layers = try XCTUnwrap(store.page?.layers)
        XCTAssertEqual(layers.count, 2, "the SVG should arrive as a layer next to what was there")
        XCTAssertTrue(layers.contains { $0.name == "Already here" }, "the existing work was replaced")
        let placed = try XCTUnwrap(layers.first { $0.name == "music" })
        guard case .group(let kids) = placed.kind else { return XCTFail("three shapes should come in as one group") }
        XCTAssertEqual(kids.count, 3)
    }
}

extension DocumentStoreTests {

    private func bubbleLayer() -> Layer {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 483, y: 0))
        p.addLine(to: CGPoint(x: 483, y: 206))
        p.addLine(to: CGPoint(x: 252, y: 206))
        p.addLine(to: CGPoint(x: 250, y: 277))
        p.addLine(to: CGPoint(x: 196, y: 206))
        p.addLine(to: CGPoint(x: 0, y: 206))
        p.closeSubpath()
        var l = Layer(kind: .path(p, closed: true))
        l.name = "Bubble"
        l.frame = CGRect(x: 0, y: 0, width: 483, height: 277)
        l.cornerRadius = 25
        return l
    }

    private func storeWithBubble() -> (DocumentStore, String) {
        var page = Page(name: "P")
        let bubble = bubbleLayer()
        page.layers = [bubble]
        var doc = Document()
        doc.pages = [page]
        let store = DocumentStore()
        store.adopt(doc, images: [:])
        return (store, bubble.id)
    }

    func testARadiusWithPointsPickedOnlyTouchesThoseCorners() throws {
        let (store, id) = storeWithBubble()
        store.setCornerRadius(0, on: id, points: [4])       // the tail tip
        let l = try XCTUnwrap(store.page?.layer(id))
        XCTAssertEqual(l.cornerRadius(at: 4), 0, "the picked corner takes the value")
        XCTAssertEqual(l.cornerRadius(at: 0), 25, "the rest keep the layer's")
        XCTAssertTrue(l.hasMixedCorners)
    }

    func testARadiusWithNothingPickedSetsTheWholeShape() throws {
        let (store, id) = storeWithBubble()
        store.setCornerRadius(0, on: id, points: [4])
        store.setCornerRadius(12, on: id, points: [])
        let l = try XCTUnwrap(store.page?.layer(id))
        XCTAssertEqual(l.cornerRadius, 12)
        XCTAssertTrue(l.cornerRadii.isEmpty, "setting the shape is the way back to corners that agree")
        XCTAssertFalse(l.hasMixedCorners)
    }

    func testTheInspectorShowsNothingWhenPickedCornersDisagree() throws {
        let (store, id) = storeWithBubble()
        store.setCornerRadius(0, on: id, points: [4])
        let l = try XCTUnwrap(store.page?.layer(id))
        XCTAssertEqual(store.cornerRadiusShown(for: l, points: [4]), 0)
        XCTAssertEqual(store.cornerRadiusShown(for: l, points: [0]), 25)
        XCTAssertNil(store.cornerRadiusShown(for: l, points: [0, 4]), "two different values is not a number")
        XCTAssertNil(store.cornerRadiusShown(for: l, points: []), "nor is a shape whose corners differ")
    }

    func testAPerPointRadiusSurvivesMovingThePointsAround() throws {
        let (store, id) = storeWithBubble()
        store.setCornerRadius(0, on: id, points: [4])
        let l = try XCTUnwrap(store.page?.layer(id))
        guard case .path(let cg, _) = l.kind else { return XCTFail("not a path") }

        // Edit the shape the way dragging a point does, then write it back.
        var vp = VectorPath(cgPath: cg, modes: l.curveModes, radii: l.cornerRadii)
        vp.points[4].point.y += 40
        store.commitEditedPath(vp, layerID: id, actionName: "Move Point")

        let after = try XCTUnwrap(store.page?.layer(id))
        XCTAssertEqual(after.cornerRadius(at: 4), 0, "the sharp corner is still the tail")
        XCTAssertEqual(after.cornerRadius(at: 0), 25)
    }

    // MARK: - Scissors

    /// A store holding one open three-point line at the root.
    private func storeWithZigzag() -> (DocumentStore, String) {
        let vp = VectorPath(points: [
            VectorPoint(CGPoint(x: 0, y: 0)),
            VectorPoint(CGPoint(x: 50, y: 60)),
            VectorPoint(CGPoint(x: 100, y: 0)),
            VectorPoint(CGPoint(x: 150, y: 60)),
        ])
        var l = Layer(kind: .path(vp.cgPath(), closed: false))
        l.name = "Zig"
        l.frame = CGRect(x: 200, y: 300, width: 150, height: 60)
        var b = Border(); b.color = .black; b.thickness = 3
        l.style.borders = [b]
        var page = Page(name: "Page 1")
        page.layers = [l]
        var doc = Document()
        doc.pages = [page]
        let store = DocumentStore()
        store.adopt(doc, images: [:])
        store.selection = [l.id]
        return (store, l.id)
    }

    func testCuttingTheMiddleOfALineMakesTwoLayersInOneUndoStep() throws {
        let (store, id) = storeWithZigzag()
        let l = try XCTUnwrap(store.page?.layer(id))
        guard case .path(let cg, _) = l.kind else { return XCTFail("not a path") }
        var head = VectorPath(cgPath: cg, modes: l.curveModes)
        let tail = try XCTUnwrap(head.cut(segment: 1))
        store.splitEditedPath(head, tail, layerID: id)

        let layers = try XCTUnwrap(store.page?.layers)
        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(layers.map(\.name), ["Zig", "Zig"], "the new piece keeps the name")
        let kept = try XCTUnwrap(store.page?.layer(id))
        let made = try XCTUnwrap(layers.first { $0.id != id })
        XCTAssertEqual(made.style.borders.first?.thickness, 3, "…and the style")
        // Each piece's frame sits on its own points, in page space.
        XCTAssertEqual(kept.frame, CGRect(x: 200, y: 300, width: 50, height: 60))
        XCTAssertEqual(made.frame, CGRect(x: 300, y: 300, width: 50, height: 60))
        XCTAssertEqual(store.selection, [id], "the original stays selected, so editing carries on")

        store.undo()
        XCTAssertEqual(store.page?.layers.count, 1, "one click, one undo")
        XCTAssertEqual(store.page?.layer(id)?.frame.width, 150)
    }
}
