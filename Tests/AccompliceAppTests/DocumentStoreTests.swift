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
