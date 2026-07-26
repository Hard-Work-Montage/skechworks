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
