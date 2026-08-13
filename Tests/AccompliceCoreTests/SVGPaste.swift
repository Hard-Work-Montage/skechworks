import CoreGraphics
import Foundation
import Testing
@testable import AccompliceCore

// SVG copied off a web page, read as shapes.

/// The music icon from lucide.dev, exactly as its Copy SVG button writes it.
private let lucideMusic = """
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" \
fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" \
stroke-linejoin="round" class="lucide lucide-music-icon lucide-music">\
<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>
"""

private func shapes(_ layers: [Layer]) -> [Layer] {
    layers.flatMap { l -> [Layer] in
        if case .group(let kids) = l.kind { return shapes(kids) }
        return [l]
    }
}

@Test func anIconFromTheWebArrivesAsItsThreeShapes() throws {
    let read = try SVGReader().read(data: Data(lucideMusic.utf8))
    let drawn = shapes(read.document.pages.first?.layers ?? [])
    #expect(drawn.count == 3, "got \(drawn.count) shapes, expected the stem and two note heads")
}

@Test func anIconDrawnInCurrentColorIsVisible() throws {
    let read = try SVGReader().read(data: Data(lucideMusic.utf8))
    let drawn = shapes(read.document.pages.first?.layers ?? [])

    // Every icon library on the web strokes in currentColor and fills nothing.
    // Read as "no colour", the icon lands on the canvas present, selectable and
    // completely invisible — the worst way for a paste to fail, because it
    // looks like nothing happened at all.
    for shape in drawn {
        #expect(!shape.style.borders.isEmpty, "\(shape.name) came in with no stroke")
        #expect(shape.style.borders.first?.thickness == 2)
    }
}

@Test func currentColorIsBlackRatherThanNothing() {
    #expect(SVGReader.color("currentColor", alpha: 1) != nil)
    #expect(SVGReader.color("none", alpha: 1) == nil)          // still means none
    #expect(SVGReader.color("url(#grad)", alpha: 1) == nil)    // still a gradient's job
}
