import Testing
import CoreGraphics
@testable import AccompliceCore

@Test func theFillPaletteSeesPastTheLayerTruncation() {
    // 250 layers; a unique colour appears only after the describe() cutoff.
    var page = Page(name: "p")
    var layers: [Layer] = []
    for i in 0..<250 {
        var l = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), closed: true))
        l.frame = CGRect(x: Double(i), y: 0, width: 10, height: 10)
        l.style.fills = [Fill(paint: .color(i < 240 ? Color.black : Color(hex: "#71706D")!))]
        layers.append(l)
    }
    page.layers = layers

    let text = page.describe(maxLayers: 200)
    #expect(text.contains("truncated at 200"))
    #expect(text.contains("#71706d"), "the palette line must include colours the tree listing cut off")
    #expect(text.contains("×10"))
}
