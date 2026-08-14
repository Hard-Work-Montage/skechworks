import CoreGraphics
import Foundation
import Testing

@testable import AccompliceCore

// An exported file starts at 0,0, whatever the artwork's address on the canvas.
//
// Writing the export box's own origin into the viewBox produces a valid file
// that previews correctly — the camera moves to match the geometry — but the
// offset then lives on the <svg> element instead of in the coordinates. Any
// consumer that lifts the paths onto its own canvas loses it, and the artwork
// lands off-screen with nothing reporting a problem.
//
// The Achieve Mint's coin templates do exactly that. A background exported at
// viewBox="2374 0 500 500" with path data drawn to match looked correct in
// their editor and engraved as a blank disc.

private func board(_ w: CGFloat = 500, _ h: CGFloat = 500, at: CGPoint = .zero,
                   containing kids: [Layer]) -> Page {
    var b = Layer(kind: .group(kids))
    b.isArtboard = true
    b.frame = CGRect(x: at.x, y: at.y, width: w, height: h)
    b.name = "Artboard"
    var p = Page(name: "t")
    p.layers = [ b ]
    return p
}

private func filled(_ rect: CGRect) -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), closed: true))
    l.frame = rect
    l.style.fills = [ Fill(paint: .color(.black)) ]
    return l
}

/// Every coordinate in the file's path data, as (x, y) pairs.
private func pathNumbers(_ svg: String) -> [(CGFloat, CGFloat)] {
    var out: [(CGFloat, CGFloat)] = []
    for d in svg.components(separatedBy: " d=\"").dropFirst() {
        guard let body = d.components(separatedBy: "\"").first else { continue }
        let nums = body.components(separatedBy: CharacterSet(charactersIn: " ,MLCQAZmlcqaz"))
            .compactMap { Double($0) }.map { CGFloat($0) }
        for i in stride(from: 0, to: nums.count - 1, by: 2) { out.append((nums[i], nums[i + 1])) }
    }
    return out
}

@Test func theViewBoxAlwaysStartsAtTheOrigin() {
    let page = board(at: CGPoint(x: 2374, y: 0),
                     containing: [ filled(CGRect(x: 0, y: 0, width: 500, height: 500)) ])
    let svg = SVGWriter().svg(page: page)

    #expect(svg.contains("viewBox=\"0 0 500 500\""),
            "expected a 0,0 origin; got \(svg.components(separatedBy: "viewBox=").last?.prefix(24) ?? "none")")
}

@Test func geometryMovesWithTheViewBoxRatherThanBeingLeftBehind() {
    let page = board(at: CGPoint(x: 2374, y: 0),
                     containing: [ filled(CGRect(x: 0, y: 0, width: 500, height: 500)) ])
    let svg = SVGWriter().svg(page: page)
    let xs = pathNumbers(svg).map(\.0)

    #expect(!xs.isEmpty, "no path data in the export")
    #expect(xs.min() ?? -1 >= -0.5, "artwork still sits at x=\(xs.min() ?? -1); it must start at 0")
    #expect(xs.max() ?? 9999 <= 500.5, "artwork runs to x=\(xs.max() ?? 9999); it must fit the 500-wide box")
}

@Test func aBoardAlreadyAtTheOriginIsUnchanged() {
    let page = board(containing: [ filled(CGRect(x: 50, y: 50, width: 100, height: 100)) ])
    let svg = SVGWriter().svg(page: page)
    let xs = pathNumbers(svg).map(\.0)

    #expect(svg.contains("viewBox=\"0 0 500 500\""))
    #expect(xs.min() ?? -1 >= 49.5, "a shape at 50 must stay at 50, not be shifted")
}

@Test func aVerticalOffsetIsNormalisedToo() {
    let page = board(at: CGPoint(x: 0, y: 900),
                     containing: [ filled(CGRect(x: 0, y: 0, width: 500, height: 500)) ])
    let svg = SVGWriter().svg(page: page)
    let ys = pathNumbers(svg).map(\.1)

    #expect(svg.contains("viewBox=\"0 0 500 500\""))
    #expect(ys.min() ?? -1 >= -0.5, "artwork still sits at y=\(ys.min() ?? -1)")
    #expect(ys.max() ?? 9999 <= 500.5)
}
