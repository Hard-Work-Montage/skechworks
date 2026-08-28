import CoreGraphics
import Testing
@testable import SkechworksCore

// What the model is told to DO with an outline drawing.
//
// Asked to decide for itself, it drew a plain rock-horns icon as one black
// silhouette of the whole hand with white shapes painted on top to carve the
// holes back out. Seven filled shapes that all had to agree, and the result was
// a black blob. Whether a picture is line art is measured, so it gets stated.

@Test func lineArtIsToldToStrokeRatherThanAsked() {
    let prompt = ModelPrompt.trace(width: 400, height: 400, lineArt: true)
    #expect(prompt.contains("THIS IS AN OUTLINE DRAWING"))
    #expect(!prompt.contains("If the picture is an outline drawing"),
            "the measured case must not be left as a question")
}

@Test func theSilhouettePlusWhiteHolesApproachIsRuledOut() {
    let prompt = ModelPrompt.trace(width: 400, height: 400, lineArt: true)
    #expect(prompt.contains("Never fill a silhouette"))
}

@Test func anythingElseStillGetsToDecideForItself() {
    // A photo or a flat-colour logo genuinely might want filled regions.
    let prompt = ModelPrompt.trace(width: 400, height: 400, lineArt: false)
    #expect(prompt.contains("If the picture is an outline drawing"))
    #expect(!prompt.contains("THIS IS AN OUTLINE DRAWING"))
}

@Test func bothVersionsStillCarryTheRestOfTheBriefing() {
    for lineArt in [true, false] {
        let prompt = ModelPrompt.trace(width: 400, height: 400, lineArt: lineArt)
        #expect(prompt.contains("strokeCap"))
        #expect(prompt.contains("TOP LEFT"))
        #expect(prompt.contains("400 wide"))
    }
}
