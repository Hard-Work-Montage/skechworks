import Testing
import CoreGraphics
@testable import SketchyworksCore

/// What a model is told about a document it can only partly see.
///
/// A traced import runs to hundreds of layers and opens with the tracer's seam
/// paths, so the listing gets cut off long before the artwork starts. Truncation
/// then hides more than layers: it hides that a colour exists at all, and a model
/// asked to change one concludes — correctly, from what it can see — that it isn't
/// in the document.
private func stack(_ count: Int, tail: Int, colour: String, stroked: Bool = false) -> Page {
    var page = Page(name: "p")
    for i in 0..<count {
        var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                         transform: nil), closed: true))
        l.frame = CGRect(x: Double(i), y: 0, width: 10, height: 10)
        let late = i >= count - tail
        if stroked {
            var b = Border()
            b.color = late ? Color(hex: colour)! : .black
            l.style.borders = [b]
        } else {
            l.style.fills = [Fill(paint: .color(late ? Color(hex: colour)! : .black))]
        }
        page.layers.append(l)
    }
    return page
}

@Test func theFillPaletteSeesPastTheLayerTruncation() {
    let text = stack(250, tail: 10, colour: "#71706D").describe(maxLayers: 200)
    #expect(text.contains("50 more layers not listed"))
    #expect(text.contains("#71706d"), "a colour the listing cut off must still be counted")
    #expect(text.contains("×10"))
}

@Test func strokeColoursAreCountedToo() {
    // The case that started this: a vectorized import whose first several hundred
    // layers are stroke-only seam paths. Counting fills alone left a model staring
    // at a page of strokes with no way to know what colours the strokes were.
    let text = stack(250, tail: 10, colour: "#71706D", stroked: true).describe(maxLayers: 200)
    #expect(text.contains("strokes across every layer"))
    #expect(text.contains("#71706d"))
}

@Test func theCountsSayTheyCoverTheWholePage() {
    // Without this the counts are ambiguous — a model that sees a truncated tree
    // and a colour list cannot tell whether the list describes the whole document
    // or only the part it was shown, and hedges instead of acting.
    let text = stack(250, tail: 10, colour: "#71706D").describe(maxLayers: 200)
    #expect(text.contains("WHOLE page"))
    #expect(text.contains("select reaches all of it"))
    #expect(text.contains("250 layers in total"))
}

@Test func aSmallPageIsListedWholeAndSaysNothingAboutTruncation() {
    let text = stack(12, tail: 2, colour: "#71706D").describe(maxLayers: 200)
    #expect(!text.contains("more layers not listed"))
    #expect(text.contains("12 layers in total"))
}
