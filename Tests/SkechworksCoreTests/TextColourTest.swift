import CoreGraphics
import Testing

@testable import SkechworksCore

// What colour a text layer's words are.
//
// The canvas fills glyphs from the layer's style and only falls back to the
// run's own colour when there is no fill. Two places forgot that and read the
// run alone: the inline editor, which showed black words on a black speech
// bubble, and Convert to Outlines, which turned green text black on the way to
// becoming a path.

private let green = Color(r: 0, g: 0.8, b: 0.2, a: 1)

private func speechBubble() -> (Layer, TextRun) {
    var run = TextRun()
    run.string = "THAT'S FUNNY!"
    run.fontSize = 24
    // Left at the default. This is the whole point: an imported text layer
    // carries a fill and still has black underneath it.
    #expect(run.color.hex == Color.black.hex)

    var l = Layer(kind: .text(run))
    l.frame = CGRect(x: 0, y: 0, width: 300, height: 120)
    l.style.fills = [Fill(paint: .color(green))]
    return (l, run)
}

@Test func textColourComesFromTheFill() {
    let (layer, run) = speechBubble()
    #expect(textColor(of: layer, run: run).hex == green.hex)
}

@Test func textColourFallsBackToTheRunWhenNothingIsFilled() {
    var (layer, run) = speechBubble()
    layer.style.fills = []
    run.color = Color(r: 1, g: 0, b: 0, a: 1)
    #expect(textColor(of: layer, run: run).hex == run.color.hex)
}

@Test func aFullyTransparentFillIsNotTheColour() {
    var (layer, run) = speechBubble()
    layer.style.fills = [Fill(paint: .color(Color(r: 0, g: 1, b: 0, a: 0)))]
    run.color = Color(r: 1, g: 0, b: 0, a: 1)
    #expect(textColor(of: layer, run: run).hex == run.color.hex)
}

@Test func outliningTextKeepsItsFill() {
    let (layer, _) = speechBubble()
    var page = Page(name: "t")
    page.layers = [layer]

    let converted = page.convertToOutlines(layer.id)
    #expect(converted)

    let out = page.layer(layer.id)
    guard case .path = out?.kind else { Issue.record("still text"); return }
    guard case .color(let c)? = out?.style.fills.first?.paint else {
        Issue.record("lost its fill"); return
    }
    #expect(c.hex == green.hex)
}

@Test func outliningUnfilledTextWritesTheRunsColourDown() {
    var run = TextRun()
    run.string = "PLAIN"
    run.fontSize = 24
    run.color = Color(r: 0.2, g: 0.4, b: 0.9, a: 1)
    var l = Layer(kind: .text(run))
    l.frame = CGRect(x: 0, y: 0, width: 200, height: 60)
    var page = Page(name: "t")
    page.layers = [l]

    let converted = page.convertToOutlines(l.id)
    #expect(converted)

    guard case .color(let c)? = page.layer(l.id)?.style.fills.first?.paint else {
        Issue.record("no fill"); return
    }
    #expect(c.hex == run.color.hex)
}
