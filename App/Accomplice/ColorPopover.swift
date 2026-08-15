import AccompliceCore
import AppKit
import SwiftUI

/// The swatch that opens the colour popover — the custom picker that replaces the
/// system panel.
///
/// The system panel is a floating window with five tabs, none of which is the
/// spectrum square everyone reaches for first. This is the Sketch shape: square,
/// hue, alpha, channels, hex — anchored to the swatch that opened it, gone on a
/// click anywhere else.
struct ColorPopoverButton: View {
    let color: AccompliceCore.Color
    var supportsOpacity = true
    let onChange: (AccompliceCore.Color) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            ZStack {
                if supportsOpacity {
                    Checkerboard().fill(.quaternary)
                }
                Rectangle().fill(SwiftUI.Color(nsColor: color.nsColor))
            }
            .frame(width: 44, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ColorPickerPane(color: color, supportsOpacity: supportsOpacity, onChange: onChange)
        }
    }
}

/// Spectrum square, hue and alpha rails, channel fields, hex. State is HSB while
/// the pane is open: RGB round-trips lose the hue the moment saturation or
/// brightness touch zero, and the thumb would snap to the left edge mid-drag.
private struct ColorPickerPane: View {
    let supportsOpacity: Bool
    let onChange: (AccompliceCore.Color) -> Void

    @State private var hue: CGFloat
    @State private var sat: CGFloat
    @State private var bri: CGFloat
    @State private var alpha: CGFloat
    @State private var hexTyped: String
    @FocusState private var hexFocused: Bool

    init(color: AccompliceCore.Color, supportsOpacity: Bool,
         onChange: @escaping (AccompliceCore.Color) -> Void) {
        self.supportsOpacity = supportsOpacity
        self.onChange = onChange
        let ns = color.nsColor.usingColorSpace(.sRGB) ?? .black
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        _hue = State(initialValue: h)
        _sat = State(initialValue: s)
        _bri = State(initialValue: b)
        _alpha = State(initialValue: a)
        _hexTyped = State(initialValue: Self.digits(color))
    }

    var body: some View {
        VStack(spacing: 10) {
            spectrumSquare
            hueRail
            if supportsOpacity { alphaRail }
            HStack(spacing: 6) {
                channel("R", 0)
                channel("G", 1)
                channel("B", 2)
            }
            HStack(spacing: 6) {
                Button {
                    // The one thing worth keeping from the system panel.
                    NSColorSampler().show { picked in
                        guard let p = picked?.usingColorSpace(.sRGB) else { return }
                        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
                        p.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                        hue = h; sat = s; bri = b
                        push()
                    }
                } label: { Image(systemName: "eyedropper") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Pick a color from the screen")
                HStack(spacing: 3) {
                    Text("#").foregroundStyle(.tertiary)
                    TextField("", text: $hexTyped)
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                        .focused($hexFocused)
                        .onSubmit(commitHex)
                        .onChange(of: hexFocused) { _, f in if !f { commitHex() } }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
                if supportsOpacity {
                    let boundAlpha = Binding(
                        get: { Int((alpha * 100).rounded()) },
                        set: { alpha = CGFloat(min(100, max(0, $0))) / 100; push() }
                    )
                    HStack(spacing: 2) {
                        TextField("", value: boundAlpha, format: .number)
                            .textFieldStyle(.plain)
                            .font(.callout.monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .frame(width: 30)
                            .stepsWithArrows { delta in
                                boundAlpha.wrappedValue = min(100, max(0, boundAlpha.wrappedValue + Int(delta)))
                            }
                        Text("%").foregroundStyle(.tertiary).font(.callout)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
                    .frame(width: 62)
                }
            }
        }
        .padding(12)
        .frame(width: 232)
    }

    // MARK: - The square

    private var spectrumSquare: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(SwiftUI.Color(hue: hue, saturation: 1, brightness: 1))
                LinearGradient(colors: [.white, .white.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black],
                               startPoint: .top, endPoint: .bottom)
                thumb(filled: true)
                    .offset(x: sat * geo.size.width - 7, y: (1 - bri) * geo.size.height - 7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                sat = min(1, max(0, g.location.x / geo.size.width))
                bri = min(1, max(0, 1 - g.location.y / geo.size.height))
                push()
            })
        }
        .frame(height: 140)
    }

    // MARK: - Rails

    private var hueRail: some View {
        rail(gradient: LinearGradient(
            colors: (0...6).map { SwiftUI.Color(hue: Double($0) / 6, saturation: 1, brightness: 1) },
            startPoint: .leading, endPoint: .trailing
        ), value: hue, thumbColor: SwiftUI.Color(hue: hue, saturation: 1, brightness: 1)) { v in
            hue = v
            push()
        }
    }

    private var alphaRail: some View {
        let c = SwiftUI.Color(hue: hue, saturation: sat, brightness: bri)
        return rail(gradient: LinearGradient(colors: [c.opacity(0), c],
                                             startPoint: .leading, endPoint: .trailing),
                    value: alpha,
                    thumbColor: c.opacity(alpha),
                    checkered: true) { v in
            alpha = v
            push()
        }
    }

    private func rail(gradient: LinearGradient, value: CGFloat, thumbColor: SwiftUI.Color,
                      checkered: Bool = false, set: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if checkered { Checkerboard().fill(.quaternary) }
                gradient
                thumb(color: thumbColor)
                    .offset(x: value * (geo.size.width - 14))
            }
            .clipShape(Capsule())
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                set(min(1, max(0, (g.location.x - 7) / (geo.size.width - 14))))
            })
        }
        .frame(height: 14)
    }

    private func thumb(color: SwiftUI.Color = .clear, filled: Bool = false) -> some View {
        Circle()
            .fill(filled ? SwiftUI.Color(hue: hue, saturation: sat, brightness: bri) : color)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 1)
    }

    // MARK: - Channels

    private func channel(_ label: String, _ idx: Int) -> some View {
        let bound = Binding(get: { rgb255[idx] }, set: { setChannel(idx, to: $0) })
        return HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary).font(.callout)
            TextField("", value: bound, format: .number)
                .textFieldStyle(.plain)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .stepsWithArrows { delta in
                    bound.wrappedValue = min(255, max(0, bound.wrappedValue + Int(delta)))
                }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
    }

    private var current: AccompliceCore.Color {
        let ns = NSColor(hue: hue, saturation: sat, brightness: bri, alpha: alpha)
            .usingColorSpace(.sRGB) ?? .black
        return AccompliceCore.Color(r: ns.redComponent, g: ns.greenComponent,
                                    b: ns.blueComponent, a: ns.alphaComponent)
    }

    private var rgb255: [Int] {
        let c = current
        return [Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded())]
    }

    private func setChannel(_ idx: Int, to value: Int) {
        var v = rgb255
        v[idx] = min(255, max(0, value))
        adopt(NSColor(srgbRed: CGFloat(v[0]) / 255, green: CGFloat(v[1]) / 255,
                      blue: CGFloat(v[2]) / 255, alpha: alpha))
    }

    private func commitHex() {
        guard let c = AccompliceCore.Color(hex: hexTyped, alpha: alpha) else {
            hexTyped = Self.digits(current)
            return
        }
        adopt(c.nsColor)
    }

    /// The six digits on their own. `Color.hex` carries a hash because SVG wants
    /// one, and the field draws its own in grey to the left, so the value showed
    /// up as ## FFFFFF. Pasting a hash in still works: the parser drops it.
    private static func digits(_ c: AccompliceCore.Color) -> String {
        let s = c.hex.uppercased()
        return s.hasPrefix("#") ? String(s.dropFirst()) : s
    }

    /// Takes an RGB colour into the HSB state. Greys have no hue of their own, so
    /// they keep the current one — otherwise typing 0 into a channel would also
    /// yank the hue thumb to red.
    private func adopt(_ ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? .black
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s > 0 { hue = h }
        sat = s; bri = b
        push()
    }

    private func push() {
        hexTyped = Self.digits(current)
        onChange(current)
    }
}

/// The classic transparency backdrop, sized for swatches and rails.
private struct Checkerboard: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let s: CGFloat = 5
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : s)
            while x < rect.maxX {
                p.addRect(CGRect(x: x, y: y, width: s, height: s)
                    .intersection(rect))
                x += s * 2
            }
            y += s
            row += 1
        }
        return p
    }
}
