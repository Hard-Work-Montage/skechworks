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
        if let path = run.onPath { return alongPath(run, path: path) }
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

// MARK: - Text along a path

extension TextOutline {

    /// Lays a run along an arbitrary path.
    ///
    /// Same idea as the arc, without assuming a circle: walk the path by arc length,
    /// and place each glyph at its own distance with its own tangent. Advances come
    /// from CoreText's straight layout and are reused as distance along the path, so
    /// kerning and the font's metrics still apply.
    static func alongPath(_ run: TextRun, path: CGPath) -> CGPath? {
        let ctFont = font(run)
        let string = run.string.replacingOccurrences(of: "\n", with: " ")
        guard !string.isEmpty else { return nil }

        let walk = PathWalk(path)
        guard walk.length > 0.01 else { return nil }

        var attrs: [CFString: Any] = [kCTFontAttributeName: ctFont]
        if run.kerning != 0 { attrs[kCTKernAttributeName] = run.kerning }
        let astr = CFAttributedStringCreate(nil, string as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(astr)
        let total = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

        // Where the text starts, from its alignment — the same choice Sketch offers,
        // and the reason a centred label stays centred when the words change.
        //
        // Centred means centred along the length. I tried anchoring closed paths at
        // their start point instead, on the theory that six labels sharing a ring must
        // be distinguished by where each was drawn from; it put them off the artboard
        // entirely. Sketch's exact rule for a closed path is still unknown here — see
        // the note in SketchReader.
        let start: CGFloat
        switch run.alignment {
        case .center:    start = (walk.length - total) / 2
        case .right:     start = walk.length - total
        default:         start = 0
        }

        let out = CGMutablePath()
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
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                // The middle of the glyph decides where it sits, so wide letters don't
                // lean out of the curve.
                let middle = start + positions[i].x + advances[i].width / 2
                guard let spot = walk.point(at: middle) else { continue }
                var t = CGAffineTransform(translationX: spot.point.x, y: spot.point.y)
                    .rotated(by: spot.angle)
                    .translatedBy(x: -advances[i].width / 2, y: 0)
                    .scaledBy(x: 1, y: -1)      // glyph outlines are y-up
                out.addPath(glyph, transform: t)
                _ = t
            }
        }
        return out.isEmpty ? nil : out.copy()
    }
}

/// Flattens a path once so it can be walked by distance.
///
/// Sampling the curve on every glyph would be quadratic and, worse, inconsistent —
/// two glyphs at the same distance have to land in the same place.
struct PathWalk {
    private var points: [CGPoint] = []
    private var distances: [CGFloat] = [0]

    var length: CGFloat { distances.last ?? 0 }
    /// True when the path comes back to where it started.
    private(set) var isClosed = false

    init(_ path: CGPath) {
        var current = CGPoint.zero
        var start = CGPoint.zero
        var flat: [CGPoint] = []

        func add(_ p: CGPoint) {
            if flat.isEmpty || hypot(p.x - flat[flat.count - 1].x, p.y - flat[flat.count - 1].y) > 0.01 {
                flat.append(p)
            }
        }
        func curve(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint) {
            // Enough steps that a coin-sized ring reads as smooth; the walk is built
            // once per layer, not per glyph.
            let steps = 24
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps), mt = 1 - t
                add(CGPoint(x: mt*mt*mt*a.x + 3*mt*mt*t*c1.x + 3*mt*t*t*c2.x + t*t*t*b.x,
                            y: mt*mt*mt*a.y + 3*mt*mt*t*c1.y + 3*mt*t*t*c2.y + t*t*t*b.y))
            }
        }

        path.applyWithBlock { e in
            let p = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint:
                current = p[0]; start = p[0]; add(current)
            case .addLineToPoint:
                current = p[0]; add(current)
            case .addQuadCurveToPoint:
                let c1 = CGPoint(x: current.x + 2.0/3 * (p[0].x - current.x),
                                 y: current.y + 2.0/3 * (p[0].y - current.y))
                let c2 = CGPoint(x: p[1].x + 2.0/3 * (p[0].x - p[1].x),
                                 y: p[1].y + 2.0/3 * (p[0].y - p[1].y))
                curve(current, c1, c2, p[1]); current = p[1]
            case .addCurveToPoint:
                curve(current, p[0], p[1], p[2]); current = p[2]
            case .closeSubpath:
                add(start); current = start
            @unknown default: break
            }
        }

        points = flat
        if let a = flat.first, let b = flat.last {
            isClosed = hypot(b.x - a.x, b.y - a.y) < 0.5
        }
        distances = [0]
        for i in 1..<max(1, flat.count) {
            distances.append(distances[i-1] + hypot(flat[i].x - flat[i-1].x, flat[i].y - flat[i-1].y))
        }
    }

    /// The point and tangent angle at a distance along the path.
    ///
    /// A closed path wraps rather than clamping, so text centred on the start point
    /// runs off one end and back on at the other instead of piling up at the seam.
    func point(at distance: CGFloat) -> (point: CGPoint, angle: CGFloat)? {
        guard points.count >= 2 else { return nil }
        var d = distance
        if isClosed, length > 0 {
            d = d.truncatingRemainder(dividingBy: length)
            if d < 0 { d += length }
        }
        d = min(max(d, 0), length)
        var i = 1
        while i < distances.count - 1 && distances[i] < d { i += 1 }
        let a = points[i-1], b = points[i]
        let span = distances[i] - distances[i-1]
        let t = span > 0.0001 ? (d - distances[i-1]) / span : 0
        return (CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                atan2(b.y - a.y, b.x - a.x))
    }
}
