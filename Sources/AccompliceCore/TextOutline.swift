import CoreGraphics
import CoreText
import Foundation

// Converts a text run to outlines.
//
// Text becomes paths on the way out, always. Adam's output is engraving SVG, where a
// live <text> element is a liability — it depends on the cutter having the font. This
// is the same call his Rails template pipeline already makes with svg_path_data.

public enum TextOutline {

    public static func font(_ run: TextRun) -> CTFont {
        let f = CTFontCreateWithName(run.fontName as CFString, run.fontSize, nil)
        // CoreText silently substitutes when a PostScript name is unknown; report it
        // so a missing font is a visible problem, not a quietly wrong coin.
        let actual = CTFontCopyPostScriptName(f) as String
        if actual.lowercased() != run.fontName.lowercased() {
            MissingFonts.note(requested: run.fontName, got: actual)
        }
        return f
    }

    /// Outlines the run inside `frame`, in the layer's local coordinate space (y-down).
    public static func path(_ run: TextRun, in frame: CGRect) -> CGPath? {
        if let arc = run.arc { return arcPath(run, arc: arc, in: frame) }
        let ctFont = font(run)
        let lines = run.string.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }

        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        let step = run.lineHeight > 0 ? run.lineHeight : (ascent + descent + leading)

        let out = CGMutablePath()
        var y = ascent

        for line in lines {
            // CoreText keys directly — AppKit's NSAttributedString.Key isn't available
            // in a Foundation-only target, and we want this to stay UI-framework free.
            var attrs: [CFString: Any] = [kCTFontAttributeName: ctFont]
            if run.kerning != 0 { attrs[kCTKernAttributeName] = run.kerning }
            let astr = CFAttributedStringCreate(nil, line as CFString, attrs as CFDictionary)!
            let ct = CTLineCreateWithAttributedString(astr)
            let width = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))

            var x: CGFloat = 0
            switch run.alignment {
            case .center: x = (frame.width - width) / 2
            case .right:  x = frame.width - width
            default:      x = 0
            }

            for r in (CTLineGetGlyphRuns(ct) as! [CTRun]) {
                let n = CTRunGetGlyphCount(r)
                guard n > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: n)
                var positions = [CGPoint](repeating: .zero, count: n)
                CTRunGetGlyphs(r, CFRangeMake(0, n), &glyphs)
                CTRunGetPositions(r, CFRangeMake(0, n), &positions)
                let runFont = (CTRunGetAttributes(r) as NSDictionary)[kCTFontAttributeName] as! CTFont

                for i in 0..<n {
                    guard let g = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                    // Glyph paths come out y-up; flip into our y-down canvas.
                    var t = CGAffineTransform(translationX: x + positions[i].x, y: y)
                        .scaledBy(x: 1, y: -1)
                    out.addPath(g, transform: t)
                    _ = t
                }
            }
            y += step
        }
        return out.isEmpty ? nil : out.copy()
    }

    /// Lays the run around a circle centred on the layer's frame.
    ///
    /// Glyphs are placed one at a time rather than as a line: each sits at its own
    /// angle with its own rotation, which is what makes the text follow the curve
    /// instead of shearing along a chord.
    ///
    /// Angles are clockwise from 12 o'clock. In this y-down space a point at θ is
    /// (sin θ, -cos θ) from the centre and the tangent is (cos θ, sin θ), so a plain
    /// rotation by θ already lines a glyph's baseline up with the curve.
    private static func arcPath(_ run: TextRun, arc: TextArc, in frame: CGRect) -> CGPath? {
        let ctFont = font(run)
        // One ring, one line. Newlines would need a second radius to mean anything,
        // and a space is what someone typing a curved label meant anyway.
        let string = run.string.replacingOccurrences(of: "\n", with: " ")
        guard !string.isEmpty, arc.radius > 0 else { return nil }

        var attrs: [CFString: Any] = [kCTFontAttributeName: ctFont]
        if run.kerning != 0 { attrs[kCTKernAttributeName] = run.kerning }
        let astr = CFAttributedStringCreate(nil, string as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(astr)

        // Positions along the (straight) line give the advances; the arc reuses them
        // as arc length, so kerning and the font's own metrics still apply.
        var placed: [(glyph: CGGlyph, font: CTFont, x: CGFloat, width: CGFloat)] = []
        for r in (CTLineGetGlyphRuns(line) as! [CTRun]) {
            let n = CTRunGetGlyphCount(r)
            guard n > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            var advances = [CGSize](repeating: .zero, count: n)
            CTRunGetGlyphs(r, CFRangeMake(0, n), &glyphs)
            CTRunGetPositions(r, CFRangeMake(0, n), &positions)
            CTRunGetAdvances(r, CFRangeMake(0, n), &advances)
            let runFont = (CTRunGetAttributes(r) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for i in 0..<n {
                placed.append((glyphs[i], runFont, positions[i].x, advances[i].width))
            }
        }
        guard !placed.isEmpty else { return nil }

        let total = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let centre = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let start = arc.angle * .pi / 180
        let direction: CGFloat = arc.flipped ? -1 : 1
        let out = CGMutablePath()

        for g in placed {
            guard let glyph = CTFontCreatePathForGlyph(g.font, g.glyph, nil) else { continue }
            // Distance from the middle of the string to the middle of this glyph,
            // as arc length; dividing by the radius turns it into an angle.
            let midpoint = g.x + g.width / 2 - total / 2
            let theta = start + direction * midpoint / arc.radius
            let p = CGPoint(x: centre.x + arc.radius * sin(theta),
                            y: centre.y - arc.radius * cos(theta))

            // Flipped text runs the other way with the glyphs turned over, so it
            // reads upright along the bottom of a circle rather than upside down.
            var t = CGAffineTransform(translationX: p.x, y: p.y)
                .rotated(by: theta + (arc.flipped ? .pi : 0))
                .translatedBy(x: -g.width / 2, y: 0)
                .scaledBy(x: 1, y: -1)     // glyph outlines are y-up
            out.addPath(glyph, transform: t)
            _ = t
        }
        return out.isEmpty ? nil : out.copy()
    }
}

/// Collects font substitutions so the CLI can warn once at the end.
public enum MissingFonts {
    nonisolated(unsafe) private static var seen: [String: String] = [:]
    private static let lock = NSLock()

    public static func note(requested: String, got: String) {
        lock.lock(); defer { lock.unlock() }
        seen[requested] = got
    }
    public static var all: [(String, String)] {
        lock.lock(); defer { lock.unlock() }
        return seen.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        seen.removeAll()
    }
}
