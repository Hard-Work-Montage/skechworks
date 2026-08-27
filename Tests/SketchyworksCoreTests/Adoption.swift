import CoreGraphics
import Foundation
import Testing

@testable import SketchyworksCore

// An artboard is the export unit and it clips its contents, so a shape lying on top of
// one but not inside it looks identical on the canvas and then comes out of the export
// missing. Everything that makes a layer has to put it in the right place.

private func pageWithArtboard() -> Page {
    var art = Layer(kind: .group([]))
    art.name = "Front"
    art.isArtboard = true
    art.backgroundColor = Color(r: 1, g: 1, b: 1, a: 1)
    art.frame = CGRect(x: 100, y: 100, width: 400, height: 400)
    var page = Page(name: "Page 1")
    page.layers = [art]
    return page
}

private func rect(_ f: CGRect) -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(origin: .zero, size: f.size), transform: nil),
                              closed: true))
    l.frame = f
    return l
}

@Test func aShapeDrawnOnAnArtboardBecomesItsChild() {
    var page = pageWithArtboard()
    let board = page.layers[0].id
    let l = rect(CGRect(x: 200, y: 200, width: 50, height: 50))
    page.layers.append(l)
    let adopted = page.adoptIntoArtboard(l.id)
    #expect(adopted)

    #expect(page.layers.count == 1)                      // only the artboard is top level now
    #expect(page.ancestors(of: l.id) == [board])
    // And it hasn't moved: the frame is now artboard-relative, so 200,200 on the page
    // is 100,100 inside a board whose corner is at 100,100.
    #expect(page.layer(l.id)?.frame.origin == CGPoint(x: 100, y: 100))
    #expect(page.absoluteOrigin(of: l.id) == CGPoint(x: 200, y: 200))
}

@Test func aShapeDrawnBesideAnArtboardStaysWhereItIs() {
    var page = pageWithArtboard()
    let l = rect(CGRect(x: 700, y: 700, width: 50, height: 50))
    page.layers.append(l)
    let adopted = page.adoptIntoArtboard(l.id)
    #expect(!adopted)
    #expect(page.ancestors(of: l.id).isEmpty)
    #expect(page.layer(l.id)?.frame.origin == CGPoint(x: 700, y: 700))
}

@Test func aShapeHangingOverTheEdgeIsStillDrawnOnTheArtboard() {
    // Its centre is inside, which is what makes the clipped edge worth seeing.
    var page = pageWithArtboard()
    let board = page.layers[0].id
    // Right edge is at 500; this runs out to 530 with its centre still at 490.
    let l = rect(CGRect(x: 450, y: 200, width: 80, height: 80))
    page.layers.append(l)
    let adopted = page.adoptIntoArtboard(l.id)
    #expect(adopted)
    #expect(page.ancestors(of: l.id) == [board])
}

@Test func anArtboardIsNeverSwallowedByAnother() {
    var page = pageWithArtboard()
    var second = Layer(kind: .group([]))
    second.isArtboard = true
    second.frame = CGRect(x: 150, y: 150, width: 100, height: 100)
    page.layers.append(second)
    let adopted = page.adoptIntoArtboard(second.id)
    #expect(!adopted)
    #expect(page.layers.count == 2)
}

@Test func theFrontmostArtboardWinsWhereTwoOverlap() {
    var page = pageWithArtboard()
    var second = Layer(kind: .group([]))
    second.name = "Back"
    second.isArtboard = true
    second.frame = CGRect(x: 150, y: 150, width: 300, height: 300)
    page.layers.append(second)                       // appended, so it's in front

    let l = rect(CGRect(x: 200, y: 200, width: 20, height: 20))
    page.layers.append(l)
    page.adoptIntoArtboard(l.id)
    #expect(page.ancestors(of: l.id) == [second.id])
}

@Test func insertingAShapeLandsItInTheArtboardItAppearsOn() {
    // The menu and the chat both come through Page.add, so this covers both.
    var page = pageWithArtboard()
    let board = page.layers[0].id
    var spec = AddSpec()
    spec.kind = "rect"
    guard let made = page.add(spec) else { Issue.record("nothing added"); return }
    #expect(page.ancestors(of: made) == [board])
}

@Test func namingAParentStillBeatsWhereItLands() {
    var page = pageWithArtboard()
    var group = Layer(kind: .group([]))
    group.name = "Sleeve"
    group.frame = CGRect(x: 700, y: 700, width: 100, height: 100)
    page.layers.append(group)

    var spec = AddSpec()
    spec.kind = "rect"
    spec.parent = "Sleeve"
    guard let made = page.add(spec) else { Issue.record("nothing added"); return }
    #expect(page.ancestors(of: made) == [group.id])
}

@Test func anAddedArtboardStaysAtTheTopLevel() {
    var page = pageWithArtboard()
    var spec = AddSpec()
    spec.kind = "artboard"
    spec.x = 150
    spec.y = 150
    guard let made = page.add(spec) else { Issue.record("nothing added"); return }
    #expect(page.ancestors(of: made).isEmpty)
}
