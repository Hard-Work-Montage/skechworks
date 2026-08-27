import Foundation
import Testing
@testable import SketchyworksCore

// A reply wrapped in something is still a reply.
//
// Found live: a trace came back with six correctly stroked paths inside a
// ```json fence, decoded to zero commands, and the draw loop stopped there
// believing the model had nothing to add. The request had asked for JSON and
// nothing else; the model fenced it regardless.

private let good = """
{"plan":"6 stroked paths","say":"drew it","commands":[
  {"op":"add","kind":"path","name":"Index finger","d":"M120 300 L120 140",
   "stroke":"#000000","strokeWidth":19}]}
"""

@Test func aFencedReplyIsRead() {
    let fenced = "```json\n\(good)\n```"
    let turn = ModelTurn.decode(Data(fenced.utf8))
    #expect(turn.commands.count == 1)
    #expect(turn.plan == "6 stroked paths")
    #expect(turn.say == "drew it")
}

@Test func aFenceWithNoLanguageTagIsRead() {
    let turn = ModelTurn.decode(Data("```\n\(good)\n```".utf8))
    #expect(turn.commands.count == 1)
}

@Test func aReplyWithChatBeforeItIsRead() {
    let chatty = "Sure! Here's the drawing:\n\n\(good)\n\nLet me know."
    let turn = ModelTurn.decode(Data(chatty.utf8))
    #expect(turn.commands.count == 1)
    #expect(turn.plan == "6 stroked paths")
}

@Test func plainJsonIsUntouched() {
    let turn = ModelTurn.decode(Data(good.utf8))
    #expect(turn.commands.count == 1)
    #expect(turn.say == "drew it")
}

@Test func aBareArrayOfCommandsStillWorks() {
    let turn = ModelTurn.decode(Data(#"[{"op":"delete","type":"path"}]"#.utf8))
    #expect(turn.commands.count == 1)
}

@Test func genuineRubbishIsStillReportedAsRubbish() {
    // Unwrapping must not turn "the model failed" into a silent success.
    let turn = ModelTurn.decode(Data("I can't do that.".utf8))
    #expect(turn.commands.isEmpty)
    #expect(!turn.problems.isEmpty)
}

@Test func theStrokedPathSurvivesTheFenceIntact() {
    // The values are the point — a fence must not cost the width or the colour.
    let turn = ModelTurn.decode(Data("```json\n\(good)\n```".utf8))
    var page = Page(name: "t")
    _ = page.run(turn.commands)
    let layer = page.layers.last
    #expect(layer?.style.fills.isEmpty == true, "it must still come out hollow")
    #expect(layer?.style.borders.first?.thickness == 19)
    #expect(layer?.name == "Index finger")
}
