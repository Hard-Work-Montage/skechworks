import SkechworksCore
import AppKit
import SwiftUI

/// A colour swatch, its hex, and its alpha — the row that appears anywhere a colour
/// can be changed.
///
/// The swatch opens the custom popover picker. The hex is a real field because
/// typing `#a9a9a9` is how a brand colour actually arrives — off a style guide, out
/// of a Slack message — and hunting for it in a colour wheel is a worse version of
/// a solved problem.
///
/// Both edges report continuously while the picker is being dragged; `DocumentStore`
/// coalesces those into one undo step.
struct ColorField: View {
    let color: SkechworksCore.Color
    var supportsOpacity = true
    let onChange: (SkechworksCore.Color) -> Void

    /// Held separately so a half-typed hex isn't parsed on every keystroke — you'd
    /// never get past `#a` before it was rewritten under you.
    @State private var typed = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ColorPopoverButton(color: color, supportsOpacity: supportsOpacity,
                               onChange: onChange)

            TextField("", text: $typed)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .frame(width: 74)
                .focused($focused)
                .onSubmit(commit)
                // Only keystrokes count as editing. A programmatic set fires this
                // too, and treating it as typing froze the field on its first value
                // — then a selection change committed that stale hex onto whatever
                // got selected next.
                .onChange(of: typed) { _, _ in if focused { editing = true } }
                .onChange(of: focused) { _, f in if !f { commit() } }

            Spacer(minLength: 0)

            if supportsOpacity {
                Text("\(Int((color.a * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: signature) {
            // Don't clobber what's being typed. Anything else — the picker, an undo,
            // chat recolouring this layer — should show through immediately.
            if !editing { typed = color.hex.uppercased() }
        }
        .onDisappear { if editing { commit() } }
    }

    /// Alpha included: two colours that differ only in transparency must not compare
    /// equal here, or the field stops tracking after the first change.
    private var signature: String { "\(color.hex)\(Int(color.a * 1000))" }

    private func commit() {
        defer { editing = false }
        guard editing else { return }
        guard let c = SkechworksCore.Color(hex: typed, alpha: color.a) else {
            typed = color.hex.uppercased()      // nonsense in, previous value back
            return
        }
        typed = c.hex.uppercased()
        guard !c.matches(color) else { return }
        onChange(c)
    }
}

extension SkechworksCore.Color {
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
