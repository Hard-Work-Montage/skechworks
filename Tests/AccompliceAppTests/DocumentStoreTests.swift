import XCTest
import CoreGraphics
import AccompliceCore
@testable import Accomplice

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

    func testSavingToAPlainNameStillProducesAnAccompliceDocument() throws {
        // The save panel now offers just the base name, so the URL that comes back has
        // no extension at all. What lands on disk still has to be a .acmplc.png that
        // opens with every layer.
        let (store, _, photo) = loaded()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acmplc-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let typed = dir.appendingPathComponent("Coin")           // exactly what's typed
        let final = typed.deletingLastPathComponent()
            .appendingPathComponent(AcmplcFile.normalisedName(typed.lastPathComponent))
        XCTAssertEqual(final.lastPathComponent, "Coin.acmplc.png")

        store.url = final
        let done = expectation(description: "written")
        store.save { ok in XCTAssertTrue(ok); done.fulfill() }
        wait(for: [done], timeout: 10)

        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        let (back, _) = try AcmplcFile.read(url: final)
        XCTAssertEqual(back.pages.count, 1)
        XCTAssertNotNil(back.pages[0].layer(photo), "the photo should have survived the save")
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
        let suite = "accomplice.tests.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    func testAnOpenedFileIsRememberedImmediately() throws {
        // The old list lived in NSDocumentController, which writes when it likes —
        // anything but a clean quit lost the lot and the menu silently emptied.
        let defaults = scratch()
        let recents = RecentDocuments(defaults: defaults)

        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recent-\(UUID().uuidString).acmplc.png")
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
            .appendingPathComponent("gone-\(UUID().uuidString).acmplc.png")
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


// MARK: - Colour

extension DocumentStoreTests {

    private func fillHex(_ store: DocumentStore, _ id: String) -> String? {
        guard case .color(let c)? = store.page?.layer(id)?.style.fills.first?.paint else { return nil }
        return c.hex
    }

    /// The system colour panel reports continuously while you drag around the wheel.
    /// One undo step per report would make ⌘Z walk back through every shade you passed
    /// through on the way to the one you wanted.
    func testDraggingThroughColoursIsOneUndoStep() {
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
    func testColouringADifferentLayerStartsANewUndoStep() {
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

    func testBorderColourAndWidthSurvive() {
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

    func testEveryVerifierIsDifferent() {
        let made = Set((0..<500).map { _ in OAuthFlow.randomVerifier() })
        XCTAssertEqual(made.count, 500, "a repeated verifier would defeat the point of PKCE")
    }

    /// Two colours of the same failure: no key at all, and a key for the wrong option.
    /// Each has to name the thing the user should go and do.
    func testUnconfiguredBackendsSayWhichSettingToChange() {
        XCTAssertTrue(ModelConnector.Failure.noKey.errorDescription?.contains("OpenRouter") == true)
        XCTAssertTrue(ModelConnector.Failure.notSignedIn.errorDescription?.contains("Accomplice") == true)
    }
}
