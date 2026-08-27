import CoreGraphics
import Foundation
import Testing

@testable import SketchyworksCore

// Naming a board in the request has to mean the board. Every other selector
// describes a layer, so "take the black off the back" used to say black and
// nothing else — and took the black off all six boards at once.

private func black(_ name: String) -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil),
                              closed: true))
    l.name = name
    l.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    l.style.fills = [Fill(paint: .color(.black))]
    return l
}

private func board(_ name: String, _ kids: [Layer]) -> Layer {
    var b = Layer(kind: .group(kids))
    b.name = name
    b.isArtboard = true
    b.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    return b
}

private func page() -> Page {
    var p = Page(name: "coin")
    p.layers = [
        board("front", [black("ring"), black("rim")]),
        board("back", [black("ring")]),
        board("back color", [black("ring"), black("plate")]),
    ]
    return p
}

@Test func aBoardNameScopesTheQueryToThatBoard() {
    let p = page()                       // one page: layer ids are made per build
    var q = LayerQuery()
    q.inside = "back color"
    q.fill = "#000000"
    let hits = p.find(q)
    #expect(hits.count == 2)
    #expect(Set(hits.compactMap { p.layer($0)?.name }) == ["ring", "plate"])
}

@Test func withoutTheBoardNameItIsStillTheWholePage() {
    var q = LayerQuery()
    q.fill = "#000000"
    #expect(page().find(q).count == 5)
}

@Test func theBoardItselfIsNeverAMatch() {
    let p = page()
    var q = LayerQuery()
    q.inside = "back color"
    // No other selector: everything ON the board, and not the board.
    let hits = p.find(q)
    #expect(hits.count == 2)
    #expect(!hits.contains { p.layer($0)?.isArtboard == true })
}

@Test func aSubstringReachesEveryBoardItNames() {
    var q = LayerQuery()
    q.inside = "back"          // matches "back" AND "back color", like every other selector
    q.fill = "#000000"
    #expect(page().find(q).count == 3)
}

@Test func nestingIsFollowedAllTheWayDown() {
    var p = Page(name: "coin")
    var inner = Layer(kind: .group([black("deep")]))
    inner.name = "artwork"
    p.layers = [board("back color", [inner]), board("front", [black("deep")])]
    var q = LayerQuery()
    q.inside = "back color"
    q.name = "deep"
    #expect(p.find(q).count == 1)
}

@Test func aBoardThatIsNotThereMatchesNothingRatherThanEverything() {
    var q = LayerQuery()
    q.inside = "sleeve"
    q.fill = "#000000"
    #expect(page().find(q).isEmpty)
}

@Test func everyPrepositionAModelReachesForMeansTheSameThing() {
    for key in ["in", "inside", "within", "parent", "artboard", "board", "onArtboard"] {
        let json: [String: Any] = ["op": "delete", key: "back color", "fill": "#000000"]
        let command = DocumentCommand.decode(json)
        #expect(command?.query.inside == "back color", "\(key) didn't scope the query")
    }
}
