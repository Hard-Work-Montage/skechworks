import CoreGraphics
import Foundation
import Testing

@testable import SkechworksCore

// A board is white to draw against and almost never white to hand on. The
// checkbox that says so has to mean the same thing in both formats: it governed
// the SVG and PNG never read it, so one export panel gave a transparent SVG and
// a PNG with the plate still under it.

private func board(fillInExport: Bool) -> Page {
    var p = Page(name: "coin")
    var b = Layer(kind: .group([]))
    b.isArtboard = true
    b.name = "back"
    b.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
    b.backgroundColor = Color(r: 1, g: 1, b: 1, a: 1)
    b.backgroundInExport = fillInExport

    var dot = Layer(kind: .path(CGPath(rect: CGRect(x: 10, y: 10, width: 20, height: 20),
                                       transform: nil), closed: true))
    dot.frame = CGRect(x: 10, y: 10, width: 20, height: 20)
    dot.style.fills = [Fill(paint: .color(.black))]
    b.kind = .group([dot])
    p.layers = [b]
    return p
}

/// The alpha of one pixel well outside the artwork but inside the board.
private func cornerAlpha(_ page: Page) -> CGFloat? {
    let r = Renderer(honorsExportFlags: true)
    guard let img = r.render(page: page, maxDimension: 40, bounds: page.layers[0].frame),
          let data = img.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else { return nil }
    // premultipliedLast, so the fourth byte of the first pixel is its alpha.
    return CGFloat(bytes[3]) / 255
}

@Test func aBoardKeepingItsFillRastersOpaque() {
    #expect(cornerAlpha(board(fillInExport: true)) == 1)
}

@Test func aBoardSkippingItsFillRastersTransparent() {
    #expect(cornerAlpha(board(fillInExport: false)) == 0)
}

@Test func theCanvasAndThumbnailStillSeeTheWhitePlate() {
    // Same board, a renderer that isn't exporting. A cover image or a picture
    // handed to a model must not come back with a hole in it.
    let r = Renderer()
    let page = board(fillInExport: false)
    guard let img = r.render(page: page, maxDimension: 40, bounds: page.layers[0].frame),
          let data = img.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
        Issue.record("nothing rendered"); return
    }
    #expect(bytes[3] == 255)
}

@Test func aFreshBoardLeavesItsFillOutOfTheExport() {
    // The default the app makes boards with. Sketch says include it; almost
    // every export here wants it gone.
    #expect(Layer(kind: .group([])).backgroundInExport == false)
}

@Test func aSavedBoardKeepsWhicheverWayItWasSet() throws {
    var doc = Document()
    var page = board(fillInExport: true)
    page.name = "coin"
    doc.pages = [page]
    let back = try SkechworksFile.read(SkechworksFile.write(document: doc, images: [:]))
    #expect(back.document.pages[0].layers[0].backgroundInExport == true)
}
