import Testing
import CoreGraphics
@testable import SketchyworksCore

@Test func anArtboardFromSelectionFitsAndAdoptsIt() {
    var photo = Layer(kind: .bitmap(imageRef: "mask.png"))
    photo.name = "hero-sky-mask"
    photo.frame = CGRect(x: 100, y: 50, width: 1280, height: 720)
    var page = Page(name: "p")
    page.layers = [photo]

    let made = page.artboardAround([photo.id])
    let board = try! #require(made.flatMap { page.layer($0) })
    #expect(board.isArtboard)
    #expect(board.frame == CGRect(x: 100, y: 50, width: 1280, height: 720))
    #expect(board.name == "hero-sky-mask")   // single selection lends its name

    // The image now lives inside the board, at its origin.
    #expect(page.ancestors(of: photo.id).contains(board.id))
    let inside = try! #require(page.layer(photo.id))
    #expect(inside.frame.origin == .zero)
    #expect(inside.frame.size == CGSize(width: 1280, height: 720))
}

@Test func anArtboardFromSelectionSpansSeveralLayers() {
    var a = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    a.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    var b = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    b.frame = CGRect(x: 300, y: 200, width: 100, height: 100)
    var page = Page(name: "p")
    page.layers = [a, b]

    let made = page.artboardAround([a.id, b.id])
    let board = try! #require(made.flatMap { page.layer($0) })
    #expect(board.frame == CGRect(x: 0, y: 0, width: 400, height: 300))
    #expect(page.children(of: board.id).count == 2)
}

@Test func artboardFromSelectionRefusesNestedAndArtboardLayers() {
    var inner = Layer(kind: .path(CGPath(rect: .init(x: 0, y: 0, width: 5, height: 5), transform: nil), closed: true))
    inner.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
    var group = Layer(kind: .group([inner]))
    group.frame = CGRect(x: 10, y: 10, width: 50, height: 50)
    var board = Layer(kind: .group([]))
    board.isArtboard = true
    board.frame = CGRect(x: 200, y: 0, width: 100, height: 100)
    var page = Page(name: "p")
    page.layers = [group, board]

    #expect(page.artboardAround([inner.id]) == nil)   // nested: not top-level
    #expect(page.artboardAround([board.id]) == nil)   // an artboard can't get a board
}
