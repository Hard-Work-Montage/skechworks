import AccompliceCore
import AppKit
import SwiftUI

/// A colour swatch, its hex, and its alpha — the row that appears anywhere a colour
/// can be changed.
///
/// The swatch is a `ColorPicker`, so it opens the system colour panel and comes with
/// the eyedropper, the palettes and the recent colours for free. The hex is a real
/// field because typing `#a9a9a9` is how a brand colour actually arrives — off a
/// style guide, out of a Slack message — and hunting for it in a colour wheel is a
/// worse version of a solved problem.
///
/// Both edges report continuously while the panel is being dragged; `DocumentStore`
/// coalesces those into one undo step.
struct ColorField: View {
    let color: AccompliceCore.Color
    var supportsOpacity = true
    let onChange: (AccompliceCore.Color) -> Void

    /// Held separately so a half-typed hex isn't parsed on every keystroke — you'd
    /// never get past `#a` before it was rewritten under you.
    @State private var typed = ""
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: Binding(
                get: { SwiftUI.Color(nsColor: color.nsColor) },
                set: { picked in
                    let c = AccompliceCore.Color(picked)
                    // The panel re-reports the colour it was handed when it opens.
                    // Without this, opening it registers an undo step for nothing.
                    guard !c.matches(color) else { return }
                    onChange(c)
                }
            ), supportsOpacity: supportsOpacity)
                .labelsHidden()
                .frame(width: 44)

            TextField("", text: $typed)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .frame(width: 74)
                .onSubmit(commit)
                .onChange(of: typed) { _, _ in editing = true }

            Spacer(minLength: 0)

            if supportsOpacity {
                Text("\(Int((color.a * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: signature) {
            // Don't clobber what's being typed. Anything else — the panel, an undo,
            // chat recolouring this layer — should show through immediately.
            if !editing { typed = color.hex.uppercased() }
        }
        .onDisappear(perform: commit)
    }

    /// Alpha included: two colours that differ only in transparency must not compare
    /// equal here, or the field stops tracking after the first change.
    private var signature: String { "\(color.hex)\(Int(color.a * 1000))" }

    private func commit() {
        defer { editing = false }
        guard let c = AccompliceCore.Color(hex: typed, alpha: color.a) else {
            typed = color.hex.uppercased()      // nonsense in, previous value back
            return
        }
        typed = c.hex.uppercased()
        guard !c.matches(color) else { return }
        onChange(c)
    }
}

extension AccompliceCore.Color {
    var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    init(_ c: SwiftUI.Color) {
        // Through sRGB explicitly: the panel hands back whatever space the user last
        // picked in, and reading components off a P3 colour as if they were sRGB
        // shifts every saturated colour.
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
        self.init(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
    }

}
