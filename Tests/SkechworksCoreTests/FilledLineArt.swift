import Foundation
import Testing
@testable import SkechworksCore

// Telling the model it filled an outline drawing.
//
// The overlay can't teach this one: solid shapes over hollow ink show up as a
// single huge red mass, which reads as every shape being in the wrong place. So
// it gets said in words, and it says the shapes are worth keeping — they
// usually are, it's only how they're drawn that's wrong.

@Test func theFloodedMessageSaysToKeepTheShapes() {
    let msg = ModelPrompt.traceAgain(report: "grid", pass: 2, filledLineArt: true)
    #expect(msg.contains("YOU FILLED THEM"))
    #expect(msg.contains("Keep them"), "redrawing from scratch throws away good geometry")
    #expect(msg.contains("take the fill OFF"))
}

@Test func aHollowDrawingIsNotAccusedOfBeingFilled() {
    let msg = ModelPrompt.traceAgain(report: "grid", pass: 2, filledLineArt: false)
    #expect(!msg.contains("YOU FILLED THEM"))
}

@Test func theStrokedExampleIsShownForLineArt() {
    // Six worked examples in the schema and not one of them had a stroke on it.
    let prompt = ModelPrompt.trace(width: 400, height: 400, lineArt: true)
    #expect(prompt.contains("\"strokeWidth\":19"))
    #expect(prompt.contains("no \"fill\" key at all"))
}

@Test func aPathWithAStrokeAndNoFillComesOutHollow() {
    // The executor's half of the contract: this is what the example promises.
    var page = Page(name: "t")
    var spec = AddSpec()
    spec.kind = "path"; spec.d = "M10 10 L100 100"
    spec.stroke = "#000000"; spec.strokeWidth = 19
    _ = page.add(spec)
    let layer = page.layers.last
    #expect(layer?.style.fills.isEmpty == true, "a stroked path must not be flooded")
    #expect(layer?.style.borders.first?.thickness == 19)
}

@Test func aPathWithNeitherStillFillsAndThatIsWhyTheExampleMatters() {
    // Omitting both keys gives a black fill, so "just leave the fill out" is not
    // on its own enough advice — the stroke has to be named.
    var page = Page(name: "t")
    var spec = AddSpec()
    spec.kind = "path"; spec.d = "M10 10 L100 100"
    _ = page.add(spec)
    #expect(page.layers.last?.style.fills.isEmpty == false)
}
