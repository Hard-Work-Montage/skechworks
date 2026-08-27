import CoreGraphics
import Testing

@testable import SketchyworksCore

// A stroke becoming a shape.
//
// The reason it exists: a border is a way of PAINTING a path, not a shape, so
// Subtract sees a circle where you can see a ring — and punches a disc out of
// the background instead of a hole.

private func ring(thickness: CGFloat = 20, position: BorderPosition = .center) -> Page {
    var l = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 200), transform: nil),
                              closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    l.name = "Oval"
    var b = Border()
    b.thickness = thickness
    b.position = position
    b.color = Color(r: 0.5, g: 0.5, b: 0.5, a: 1)
    l.style.borders = [b]
    var p = Page(name: "t")
    p.layers = [l]
    return p
}

/// A point inside the ring's hole. If the conversion worked, it isn't covered.
private func covers(_ path: CGPath, _ point: CGPoint) -> Bool {
    path.contains(point, using: .evenOdd)
}

@Test func aStrokedCircleBecomesARingWithAHoleInIt() throws {
    var p = ring()
    let ok = p.convertToOutlines(p.layers[0].id)
    #expect(ok)
    guard case .path(let cg, _) = p.layers[0].kind else { Issue.record("not a path"); return }
    #expect(covers(cg, CGPoint(x: 100, y: 3)), "the band itself should be filled")
    #expect(!covers(cg, CGPoint(x: 100, y: 100)), "the middle must be a hole — that's the whole point")
}

@Test func theStrokeBecomesTheFillAndTheBorderGoes() throws {
    var p = ring()
    let ok = p.convertToOutlines(p.layers[0].id)
    #expect(ok)
    let l = p.layers[0]
    #expect(l.style.borders.isEmpty, "a converted stroke that keeps its border draws twice")
    #expect(l.style.fills.count == 1)
    if case .color(let c)? = l.style.fills.first?.paint {
        #expect(c.hex == "#808080", "the ring should be the colour the stroke was")
    }
}

@Test func aShapeWithNoBorderIsLeftAlone() {
    var p = ring()
    p.layers[0].style.borders = []
    let ok = p.convertToOutlines(p.layers[0].id)
    #expect(!ok, "there was nothing to outline")
}

@Test func aFilledAndStrokedShapeKeepsBothColours() throws {
    // One path can only be one colour, so flattening these together would have
    // to throw one away. They become two shapes that look like what was there.
    var p = ring()
    p.layers[0].style.fills = [Fill(paint: .color(Color(r: 1, g: 0, b: 0, a: 1)))]
    let ok = p.convertToOutlines(p.layers[0].id)
    #expect(ok)
    guard case .group(let kids) = p.layers[0].kind else { Issue.record("expected a group"); return }
    #expect(kids.count == 2)
    let colours = kids.compactMap { k -> String? in
        if case .color(let c)? = k.style.fills.first?.paint { return c.hex }
        return nil
    }
    #expect(colours.contains("#ff0000"), "the fill was lost")
    #expect(colours.contains("#808080"), "the stroke colour was lost")
    #expect(kids.allSatisfy { $0.style.borders.isEmpty })
}

@Test func anInsideBorderStaysInsideTheShape() throws {
    var p = ring(thickness: 20, position: .inside)
    let ok = p.convertToOutlines(p.layers[0].id)
    #expect(ok)
    guard case .path(let cg, _) = p.layers[0].kind else { return }
    // An inside stroke can't stick out past the circle it belongs to.
    #expect(cg.boundingBoxOfPath.width <= 201)
    #expect(!covers(cg, CGPoint(x: 100, y: 100)))
}

@Test func textBecomesItsLetters() throws {
    var run = TextRun()
    run.string = "Hi"
    run.fontSize = 48
    var l = Layer(kind: .text(run))
    l.frame = CGRect(x: 0, y: 0, width: 200, height: 60)
    var p = Page(name: "t")
    p.layers = [l]
    let ok = p.convertToOutlines(l.id)
    #expect(ok)
    if case .path(let cg, _) = p.layers[0].kind {
        #expect(!cg.isEmpty)
    } else {
        Issue.record("text did not become a path")
    }
}
