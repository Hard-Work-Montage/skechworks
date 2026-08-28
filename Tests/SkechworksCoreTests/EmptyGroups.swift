import Testing
import CoreGraphics
@testable import SkechworksCore

private func path(_ x: CGFloat) -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
    l.frame = CGRect(x: x, y: 0, width: 10, height: 10)
    return l
}

@Test func ungroupingAnEmptyGroupRemovesTheShell() {
    var empty = Layer(kind: .group([]))
    empty.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    var page = Page(name: "p")
    page.layers = [empty, path(50)]

    page.ungroup(empty.id)
    #expect(page.layer(empty.id) == nil, "the husk is gone")
    #expect(page.layers.count == 1)
}

@Test func theEmptyQueryFindsOnlyHollowContainers() {
    var full = Layer(kind: .group([path(0)]))
    full.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    var hollow = Layer(kind: .group([]))
    hollow.frame = CGRect(x: 20, y: 0, width: 10, height: 10)
    var page = Page(name: "p")
    page.layers = [full, hollow, path(40)]

    var q = LayerQuery()
    q.empty = true
    #expect(page.find(q) == [hollow.id])

    q.empty = false
    let nonEmpty = page.find(q)
    #expect(nonEmpty.contains(full.id) && !nonEmpty.contains(hollow.id))

    // And describe() flags it, so a model knows the husk exists.
    #expect(page.describe().contains("empty"))
}
