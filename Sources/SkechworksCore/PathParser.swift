import CoreGraphics
import Foundation

// SVG path data -> CGPath.
//
// The document format stores geometry as SVG path syntax rather than a bespoke
// encoding, so this is what reads it back. It also means someone can hand-edit a
// page's JSON in a text editor and we'll still understand it — which is most of the
// reason for choosing that representation in the first place.

public enum PathParser {

    public static func path(from d: String) -> CGPath {
        let p = CGMutablePath()
        var scanner = Lexer(d)
        var cur = CGPoint.zero          // current point
        var start = CGPoint.zero        // subpath start, for Z
        var lastControl: CGPoint?       // for S / T smoothing
        var lastCommand: Character = " "

        while let cmd = scanner.command() {
            let rel = cmd.isLowercase
            let c = Character(cmd.uppercased())

            repeat {
                switch c {
                case "M":
                    guard let x = scanner.number(), let y = scanner.number() else { break }
                    cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                    p.move(to: cur)
                    start = cur
                    lastControl = nil
                    // Per spec, extra pairs after a moveto are implicit linetos.
                    while scanner.peekIsNumber() {
                        guard let x2 = scanner.number(), let y2 = scanner.number() else { break }
                        cur = rel ? CGPoint(x: cur.x + x2, y: cur.y + y2) : CGPoint(x: x2, y: y2)
                        p.addLine(to: cur)
                    }

                case "L":
                    guard let x = scanner.number(), let y = scanner.number() else { break }
                    cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                    p.addLine(to: cur)
                    lastControl = nil

                case "H":
                    guard let x = scanner.number() else { break }
                    cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y)
                    p.addLine(to: cur)
                    lastControl = nil

                case "V":
                    guard let y = scanner.number() else { break }
                    cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y)
                    p.addLine(to: cur)
                    lastControl = nil

                case "C":
                    guard let x1 = scanner.number(), let y1 = scanner.number(),
                          let x2 = scanner.number(), let y2 = scanner.number(),
                          let x = scanner.number(), let y = scanner.number() else { break }
                    let c1 = rel ? CGPoint(x: cur.x + x1, y: cur.y + y1) : CGPoint(x: x1, y: y1)
                    let c2 = rel ? CGPoint(x: cur.x + x2, y: cur.y + y2) : CGPoint(x: x2, y: y2)
                    cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                    p.addCurve(to: cur, control1: c1, control2: c2)
                    lastControl = c2

                case "S":
                    guard let x2 = scanner.number(), let y2 = scanner.number(),
                          let x = scanner.number(), let y = scanner.number() else { break }
                    let reflected = (lastCommand == "C" || lastCommand == "S")
                        ? CGPoint(x: 2 * cur.x - (lastControl?.x ?? cur.x),
                                  y: 2 * cur.y - (lastControl?.y ?? cur.y))
                        : cur
                    let c2 = rel ? CGPoint(x: cur.x + x2, y: cur.y + y2) : CGPoint(x: x2, y: y2)
                    cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                    p.addCurve(to: cur, control1: reflected, control2: c2)
                    lastControl = c2

                case "Q":
                    guard let x1 = scanner.number(), let y1 = scanner.number(),
                          let x = scanner.number(), let y = scanner.number() else { break }
                    let c1 = rel ? CGPoint(x: cur.x + x1, y: cur.y + y1) : CGPoint(x: x1, y: y1)
                    cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                    p.addQuadCurve(to: cur, control: c1)
                    lastControl = c1

                case "T":
                    guard let x = scanner.number(), let y = scanner.number() else { break }
                    let reflected = (lastCommand == "Q" || lastCommand == "T")
                        ? CGPoint(x: 2 * cur.x - (lastControl?.x ?? cur.x),
                                  y: 2 * cur.y - (lastControl?.y ?? cur.y))
                        : cur
                    cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                    p.addQuadCurve(to: cur, control: reflected)
                    lastControl = reflected

                case "A":
                    // Elliptical arcs: we never emit them, but third-party SVG uses them.
                    guard let rx = scanner.number(), let ry = scanner.number(),
                          let rot = scanner.number(), let large = scanner.number(),
                          let sweep = scanner.number(),
                          let x = scanner.number(), let y = scanner.number() else { break }
                    let to = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                    addArc(p, from: cur, to: to, rx: rx, ry: ry, rotation: rot,
                           largeArc: large != 0, sweep: sweep != 0)
                    cur = to
                    lastControl = nil

                case "Z":
                    p.closeSubpath()
                    cur = start
                    lastControl = nil

                default:
                    break
                }
                lastCommand = c
                // A command repeats while more numbers follow it (except Z, which takes none).
            } while c != "Z" && c != "M" && scanner.peekIsNumber()
        }
        return p.copy() ?? p
    }

    /// Endpoint-parameterized arc -> cubic segments (SVG implementation notes, F.6.5).
    private static func addArc(_ p: CGMutablePath, from: CGPoint, to: CGPoint,
                               rx: CGFloat, ry: CGFloat, rotation: CGFloat,
                               largeArc: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        if rx == 0 || ry == 0 { p.addLine(to: to); return }
        let phi = rotation * .pi / 180
        let dx2 = (from.x - to.x) / 2, dy2 = (from.y - to.y) / 2
        let x1 = cos(phi) * dx2 + sin(phi) * dy2
        let y1 = -sin(phi) * dx2 + cos(phi) * dy2

        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }

        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let num = max(0, rx*rx*ry*ry - rx*rx*y1*y1 - ry*ry*x1*x1)
        let den = rx*rx*y1*y1 + ry*ry*x1*x1
        let co = den == 0 ? 0 : sign * sqrt(num / den)
        let cx1 = co * rx * y1 / ry
        let cy1 = -co * ry * x1 / rx
        let cx = cos(phi) * cx1 - sin(phi) * cy1 + (from.x + to.x) / 2
        let cy = sin(phi) * cx1 + cos(phi) * cy1 + (from.y + to.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux*ux + uy*uy) * sqrt(vx*vx + vy*vy)
            guard len != 0 else { return 0 }
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segs = Int(ceil(abs(delta) / (.pi / 2)))
        let inc = delta / CGFloat(max(1, segs))
        var t1 = theta1
        var pt = from
        for _ in 0..<max(1, segs) {
            let t2 = t1 + inc
            let alpha = 4.0 / 3.0 * tan(inc / 4)
            let c1 = CGPoint(x: pt.x - alpha * (cos(phi) * rx * sin(t1) + sin(phi) * ry * cos(t1)),
                             y: pt.y - alpha * (sin(phi) * rx * sin(t1) - cos(phi) * ry * cos(t1)))
            let e = CGPoint(x: cos(phi) * rx * cos(t2) - sin(phi) * ry * sin(t2) + cx,
                            y: sin(phi) * rx * cos(t2) + cos(phi) * ry * sin(t2) + cy)
            let c2 = CGPoint(x: e.x + alpha * (cos(phi) * rx * sin(t2) + sin(phi) * ry * cos(t2)),
                             y: e.y + alpha * (sin(phi) * rx * sin(t2) - cos(phi) * ry * cos(t2)))
            p.addCurve(to: e, control1: c1, control2: c2)
            pt = e; t1 = t2
        }
    }

    private struct Lexer {
        private let s: [Character]
        private var i = 0
        init(_ str: String) { s = Array(str) }

        mutating func skip() {
            while i < s.count, s[i] == " " || s[i] == "," || s[i] == "\n" || s[i] == "\t" || s[i] == "\r" { i += 1 }
        }
        mutating func command() -> Character? {
            skip()
            guard i < s.count, s[i].isLetter else { return nil }
            defer { i += 1 }
            return s[i]
        }
        mutating func peekIsNumber() -> Bool {
            skip()
            guard i < s.count else { return false }
            return s[i].isNumber || s[i] == "-" || s[i] == "+" || s[i] == "."
        }
        mutating func number() -> CGFloat? {
            skip()
            guard i < s.count else { return nil }
            var out = ""
            if s[i] == "-" || s[i] == "+" { out.append(s[i]); i += 1 }
            var sawDot = false, sawExp = false
            while i < s.count {
                let c = s[i]
                if c.isNumber { out.append(c); i += 1 }
                else if c == "." && !sawDot && !sawExp { sawDot = true; out.append(c); i += 1 }
                else if (c == "e" || c == "E") && !sawExp && !out.isEmpty {
                    sawExp = true; out.append(c); i += 1
                    if i < s.count, s[i] == "-" || s[i] == "+" { out.append(s[i]); i += 1 }
                } else { break }
            }
            guard let d = Double(out) else { return nil }
            return CGFloat(d)
        }
    }
}
