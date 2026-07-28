import AppKit
import SwiftUI

// The surfaces the app is made of.
//
// Named and gathered rather than reached for at each call site, because the whole
// point is that they relate to each other: rails a shade lighter than the canvas
// around the artwork, so the page reads as the thing you're looking at and the panels
// recede. macOS's stock underPageBackgroundColor is far darker than that — it's meant
// for a document on a desk, not for a canvas you work across.
//
// Every one is dynamic. A tool people keep open all day gets used in both appearances.
enum Palette {
    /// Behind the artwork. Light enough that a white artboard still reads as white,
    /// dark enough to see where the page ends.
    static let canvas = dynamic(light: NSColor(calibratedWhite: 0.925, alpha: 1),
                                dark: NSColor(calibratedWhite: 0.16, alpha: 1))

    /// The panels either side.
    static let rail = dynamic(light: .white,
                              dark: NSColor(calibratedWhite: 0.12, alpha: 1))

    /// Hairlines between panels and above section headers.
    static let divider = dynamic(light: NSColor(calibratedWhite: 0.87, alpha: 1),
                                 dark: NSColor(calibratedWhite: 0.24, alpha: 1))

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

extension SwiftUI.Color {
    static let canvasSurround = SwiftUI.Color(nsColor: Palette.canvas)
    static let rail = SwiftUI.Color(nsColor: Palette.rail)
    static let railDivider = SwiftUI.Color(nsColor: Palette.divider)
}
