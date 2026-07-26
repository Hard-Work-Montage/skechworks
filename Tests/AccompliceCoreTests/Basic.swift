import CoreGraphics
import Foundation
import Testing

@testable import AccompliceCore

// The polyglot is the load-bearing claim of this whole format, so it gets tested
// from both directions on every build.

@Test func zipRoundTrips() throws {
    let entries = [
        ZipEntry(name: "document.json", data: Data(#"{"format":"acmplc"}"#.utf8)),
        ZipEntry(name: "exports/page.svg", data: Data(String(repeating: "<path/>", count: 500).utf8)),
    ]
    let back = try Zip.read(Zip.write(entries))
    #expect(back.count == 2)
    #expect(String(decoding: back["document.json"]!, as: UTF8.self) == #"{"format":"acmplc"}"#)
    #expect(back["exports/page.svg"]!.count == 3500)   // survived the deflate round-trip
}

@Test func pngZipPolyglotIsBothThings() throws {
    var doc = Document()
    var page = Page(name: "One Year")
    var l = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil),
                              closed: true))
    l.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    l.style.fills = [Fill(paint: .color(.black))]
    page.layers = [l]
    doc.pages = [page]

    let data = try AcmplcFile.write(document: doc, images: [:])

    // 1. Still a PNG.
    #expect(data.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

    // 2. Still a ZIP, and the artwork is really in there.
    let back = try Zip.read(data)
    #expect(back["document.json"] != nil)
    #expect(back["README.txt"] != nil)
    let svg = back.first { $0.key.hasPrefix("exports/") && $0.key.hasSuffix(".svg") }
    let text = try #require(svg.map { String(decoding: $0.value, as: UTF8.self) })
    #expect(text.contains("<svg"))
    #expect(text.contains("<path"))
}

@Test func booleanSubtractRemovesArea() throws {
    // A ring: outer circle minus inner. Guards the CGPath boolean composition that
    // all of the coin artwork depends on.
    var outer = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil), closed: true))
    outer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    var inner = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 50, height: 50), transform: nil), closed: true))
    inner.frame = CGRect(x: 25, y: 25, width: 50, height: 50)
    inner.booleanOp = .subtract

    let group = Layer(kind: .shapeGroup([outer, inner], .nonZero))
    let p = try #require(Compose.resolvedPath(group))
    #expect(p.contains(CGPoint(x: 50, y: 5)))       // on the ring
    #expect(!p.contains(CGPoint(x: 50, y: 50)))     // hole in the middle
}

@Test func groupInsideShapeGroupStillComposes() {
    // Regression: plain groups nested inside a shapeGroup were being dropped, which
    // silently deleted the dot clusters from the moon-phases coin.
    var dot = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 20, height: 20), transform: nil), closed: true))
    dot.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
    var wrapper = Layer(kind: .group([dot]))
    wrapper.frame = CGRect(x: 40, y: 40, width: 20, height: 20)
    #expect(Compose.resolvedPath(wrapper) != nil)
}
