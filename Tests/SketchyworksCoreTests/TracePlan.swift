import Foundation
import Testing
@testable import SketchyworksCore

// The parts list a trace writes before it draws.
//
// The rock-horns failure was a strategy error — it drew a filled silhouette and
// painted white holes over it — and a strategy is only correctable while it is
// still a sentence. Planning first is where that sentence exists.

@Test func thePlanIsAskedForBeforeTheCommands() {
    let prompt = ModelPrompt.trace(width: 400, height: 400, lineArt: true)
    #expect(prompt.contains("PLAN IT FIRST"))
    // The ordering IS the mechanism: a plan written after the shapes describes
    // them instead of deciding them.
    #expect(prompt.contains("BEFORE \"commands\""))
}

@Test func aPlanIsReadBackOffTheReply() {
    let json = #"{"plan":"6 stroked paths: index, pinky, two folded fingers, thumb, palm","say":"drew it","commands":[]}"#
    let turn = ModelTurn.decode(Data(json.utf8))
    #expect(turn.plan.contains("6 stroked paths"))
    #expect(turn.say == "drew it")
}

@Test func aPlanWrittenAsAListIsKeptToo() {
    // Models write this as an array about as often as a string.
    let json = #"{"plan":["index finger: stroked path","palm: stroked path"],"commands":[]}"#
    let turn = ModelTurn.decode(Data(json.utf8))
    #expect(turn.plan.contains("index finger"))
    #expect(turn.plan.contains("palm"))
}

@Test func aReplyWithNoPlanStillDecodes() {
    // Every other caller of this — the chat — never sends one.
    let turn = ModelTurn.decode(Data(#"{"say":"hello","commands":[]}"#.utf8))
    #expect(turn.plan.isEmpty)
    #expect(turn.say == "hello")
}

@Test func laterPassesAreCorrectedAgainstThePlan() {
    let withPlan = ModelPrompt.traceAgain(report: "grid", pass: 2,
                                          plan: "index finger, pinky, palm")
    #expect(withPlan.contains("WHAT YOU SAID YOU WERE DRAWING"))
    #expect(withPlan.contains("index finger"))
    // The case the overlay alone can't teach: a part never drawn leaves no red
    // to notice, only grey that looks like every other miss.
    #expect(withPlan.contains("you never"))
}

@Test func noPlanMeansNoEmptyHeading() {
    let without = ModelPrompt.traceAgain(report: "grid", pass: 2)
    #expect(!without.contains("WHAT YOU SAID YOU WERE DRAWING"))
    #expect(without.contains("grid"), "the report itself must survive")
}
