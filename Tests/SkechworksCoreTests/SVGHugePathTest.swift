import CoreGraphics
import Foundation
import Testing

@testable import SkechworksCore

// A traced engraving saved as one compound path can carry a `d` over 10 MB, which
// libxml2 (under XMLParser) refuses outright, so the file wouldn't open at all
// (Adam, 2026-10-07: a 25 MB coin front gave only the failure beep).

@Test func aPathOverTenMegabytesStillOpens() throws {
    // Thousands of tiny squares, each with a square hole, in ONE path, past 10 MB.
    var d = ""
    var n = 0
    while d.utf8.count < 11_000_000 {
        let x = Double(n % 1000), y = Double(n / 1000)
        d += "M\(x) \(y)L\(x + 0.9) \(y)L\(x + 0.9) \(y + 0.9)L\(x) \(y + 0.9)Z"
        d += "M\(x + 0.2) \(y + 0.2)L\(x + 0.2) \(y + 0.7)L\(x + 0.7) \(y + 0.7)L\(x + 0.7) \(y + 0.2)Z"
        n += 1
    }
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="0 0 1000 1000">
      <path fill="#000000" d="\(d)"/>
    </svg>
    """
    let data = Data(svg.utf8)
    #expect(XMLParser(data: data).parse() == false, "the limit this works around is still there")

    let result = try SVGReader().read(data: data)

    let layers = result.document.pages[0].layers
    #expect(layers.count == 1)
    guard case .path(let path, _) = layers[0].kind else { Issue.record("not a path"); return }
    // Every subpath, holes included, stays in the one shape.
    var moves = 0
    path.applyWithBlock { if $0.pointee.type == .moveToPoint { moves += 1 } }
    #expect(moves == n * 2)
}

@Test func ordinaryFilesAreLeftAlone() throws {
    let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><path d="M0 0L5 0L5 5Z"/></svg>"#
    let reader = SVGReader()
    #expect(reader.stashingLongValues(Data(svg.utf8)) == Data(svg.utf8))
    #expect(try reader.read(data: Data(svg.utf8)).document.pages[0].layers.count == 1)
}
