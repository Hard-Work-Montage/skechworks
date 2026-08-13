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

// Dashed and dotted borders, out to SVG and back.

@Test func aDashedBorderSurvivesTheRoundTrip() throws {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 50),
                                     transform: nil), closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 50)
    var b = Border()
    b.thickness = 2
    b.dashPattern = [6, 4]
    l.style.borders = [b]
    var page = Page(name: "p")
    page.layers = [l]
    var doc = Document()
    doc.pages = [page]

    let back = try AcmplcFile.read(AcmplcFile.write(document: doc, images: [:]))
    #expect(back.document.pages.first?.layers.first?.style.borders.first?.dashPattern == [6, 4])

    // And out to SVG, where a dash is stroke-dasharray or it is nothing.
    let svg = SVGWriter().svg(page: page)
    #expect(svg.contains("stroke-dasharray"), "the dash never reached the export")
}

// Flattening something that has been turned.

@Test func aTurnedLayerIsMeasuredWhereItActuallySits() {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 200),
                                     transform: nil), closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 200)
    l.rotation = 30

    let box = Flatten.box(of: l)
    // Turned, a 100x200 rectangle reaches wider and taller than its frame. Only
    // the frame was ever measured, so flattening cut the two corners that stuck
    // out — a phone at a slight angle lost its top left and bottom right.
    #expect(box.width > 100)
    #expect(box.height > 200)
    // Around the same middle: it grew outward, it did not slide.
    #expect(abs(box.midX - 50) < 0.001)
    #expect(abs(box.midY - 100) < 0.001)
}

@Test func anUprightLayerIsLeftExactlyAsItWas() {
    var l = Layer(kind: .path(CGPath(rect: CGRect(x: 5, y: 7, width: 100, height: 200),
                                     transform: nil), closed: true))
    l.frame = CGRect(x: 5, y: 7, width: 100, height: 200)
    #expect(Flatten.box(of: l) == l.frame)
}

@Test func theSelectionBoxCoversEveryTurnedLayerInIt() throws {
    var a = Layer(kind: .path(CGPath(rect: .zero, transform: nil), closed: true))
    a.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    a.rotation = 45
    var b = Layer(kind: .path(CGPath(rect: .zero, transform: nil), closed: true))
    b.frame = CGRect(x: 200, y: 0, width: 50, height: 50)

    let box = try #require(Flatten.bounds(of: [a, b]))
    #expect(box.minX < 0, "the turned corner hangs past the frame and must be in the box")
    #expect(box.maxX >= 250)
}
