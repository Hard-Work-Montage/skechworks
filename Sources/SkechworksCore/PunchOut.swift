import CoreGraphics
import Foundation

/// Path ▸ Punch Out: one shape from a stack of dark and light ones.
///
/// A traced black and white drawing comes back as solid shapes in painting
/// order: the disc, the letters on top of it, the counters of the letters on
/// top of those. To get one outline with holes where the light shapes were,
/// you had to select the disc and each letter and Subtract, then the counters
/// and Union, and so on up the stack. That is a fold over the painting order
/// where every dark shape adds and every light shape cuts, and nothing about
/// it needs a person to decide which is which.
///
/// The result is ONE plain path, not a live combined shape. The first cut of
/// this kept the pieces live inside a shape group, the way Subtract does, and
/// the skull coin (651 pieces, 17,000 path elements) took twenty seconds to
/// fold in a release build — which the canvas then asked for again on every
/// mouse move, and the app never came back. A fold that size runs once, off
/// the main thread, and what it puts down has to be cheap to draw. Undo is
/// the way back to the pieces.
///
/// Three steps so the app can put the slow one on another thread: `prepare`
/// reads the page, `Prepared.fold` does the geometry, `Page.apply` writes the
/// result. `Page.punchOut` runs all three for callers that can block.
public enum PunchOut {
    public struct Refusal: Error { public let why: String }

    public enum Outcome: Equatable {
        /// The path's id, how many dark pieces went in and how many light ones
        /// cut holes.
        case made(id: String, inks: Int, holes: Int)
        case refused(String)
    }

    /// Everything the fold needs, read off the page and owned by the caller,
    /// so the page can go on being edited while the geometry runs.
    public struct Prepared: @unchecked Sendable {
        /// Pieces in painting order, each in the parent's space. Ink adds,
        /// paper cuts.
        public let pieces: [(path: CGPath, ink: Bool)]
        public let parent: String?
        /// What gets removed when the result goes down.
        public let originals: [String]
        public var inks: Int { pieces.filter(\.ink).count }
        public var holes: Int { pieces.count - inks }

        /// The fold: each dark piece keeps what the light pieces painted after
        /// it leave showing, and the kept parts together are the answer.
        ///
        /// A point ends up dark when the topmost piece over it is dark. So a dark
        /// piece only ever loses area to LIGHT pieces above it; a dark one above
        /// it paints the same ink. That makes every dark piece its own small job,
        /// all of them run at once, and no step pays for the whole drawing so far.
        ///
        /// The first fold folded one piece at a time onto a growing result, and
        /// time grew with the square of the piece count. The second folded
        /// neighbours in pairs, then pairs of pairs, which fixed small traces and
        /// still took twenty-two seconds on a coin of 7,388 pieces: the top of
        /// that bracket is a handful of unions of the entire drawing.
        ///
        /// `progress` hears (pieces done, pieces in all) from any thread.
        /// A cancelled task stops it between pieces.
        public func fold(progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> CGPath? {
            let n = pieces.count
            guard n > 0 else { return nil }
            let raw = Paths(pieces.map(\.path))
            let clean = Self.each(n) { raw.all[$0].normalized(using: .winding) }
            try Task.checkCancellation()
            let stack = Stack(paths: clean,
                              boxes: clean.map(\.boundingBoxOfPath),
                              sizes: clean.map(Self.elementCount),
                              ink: pieces.map(\.ink))

            let counter = Counter()
            var kept = [Kept?](repeating: nil, count: n)
            // One pass over every piece, so the black of a whole coin, which is a
            // couple of seconds on its own, runs beside the thousands of small
            // ones and not ahead of them. A Stop is noticed on the calling thread,
            // which takes its share of the pieces, and the rest stand down.
            let stop = Flag()
            kept.withUnsafeMutableBufferPointer { out in
                let out = UncheckedBuffer(base: out)
                DispatchQueue.concurrentPerform(iterations: n) { i in
                    if Task.isCancelled { stop.raise() }
                    guard !stop.isRaised else { return }
                    if stack.ink[i] { out.base[i] = stack.keep(i) }
                    progress?(counter.bump(), n)
                }
            }
            if stop.isRaised { throw CancellationError() }
            try Task.checkCancellation()

            // Two dark pieces that overlap have both kept the overlap. Laid side
            // by side they would paint right and still be two outlines crossing,
            // which a laser reads as a hole. Those few are merged for real; the
            // rest touch nothing and are already their own union.
            var crossing = Set<Int>()
            for (i, k) in kept.enumerated() {
                guard let k, !k.inkAbove.isEmpty else { continue }
                crossing.insert(i)
                crossing.formUnion(k.inkAbove)
            }
            let apart = CGMutablePath(), merged = CGMutablePath()
            for (i, k) in kept.enumerated() {
                guard let path = k?.path, !path.isEmpty else { continue }
                (crossing.contains(i) ? merged : apart).addPath(path)
            }
            if !merged.isEmpty { apart.addPath(merged.normalized(using: .winding)) }
            return apart.isEmpty ? nil : apart
        }

        /// `count` results computed on every core, in order.
        private static func each(_ count: Int, _ make: @escaping @Sendable (Int) -> CGPath) -> [CGPath] {
            var out = [CGPath](repeating: CGMutablePath(), count: count)
            out.withUnsafeMutableBufferPointer { buf in
                let buf = UncheckedBuffer(base: buf)
                DispatchQueue.concurrentPerform(iterations: count) { buf.base[$0] = make($0) }
            }
            return out
        }

        static func elementCount(_ path: CGPath) -> Int {
            var c = 0
            path.applyWithBlock { _ in c += 1 }
            return c
        }
    }

    struct Paths: @unchecked Sendable {
        let all: [CGPath]
        init(_ all: [CGPath]) { self.all = all }
    }

    /// What one dark piece kept, and the dark pieces above that overlap it.
    struct Kept: @unchecked Sendable {
        var path: CGPath
        var inkAbove: [Int] = []
    }

    /// The pieces, cleaned up and measured once, shared by every job.
    struct Stack: @unchecked Sendable {
        let paths: [CGPath]
        let boxes: [CGRect]
        let sizes: [Int]
        let ink: [Bool]

        /// A boolean on paths this size is worth a closer look at what goes in.
        static let worthSifting = 4000

        /// Dark piece `i` less every light piece painted after it.
        func keep(_ i: Int) -> Kept {
            let box = boxes[i]
            var paper: [Int] = [], inkAbove: [Int] = []
            var size = sizes[i]
            for j in (i + 1)..<paths.count where boxes[j].intersects(box) {
                if ink[j] { inkAbove.append(j) } else { paper.append(j); size += sizes[j] }
            }
            if paper.isEmpty && inkAbove.isEmpty { return Kept(path: paths[i]) }

            if size >= Self.worthSifting || inkAbove.count > 8 {
                // Boxes overlapping says little when this piece is the black of a
                // whole coin: its box is the coin. A piece that neither crosses
                // this one's outline nor sits on its fill cannot cut it or overlap
                // it, and on a coin with dots over the white that is most of them.
                let reach = Reach(of: paths[i], box: box)
                paper = paper.filter { reach.touches(boxes[$0]) }
                inkAbove = inkAbove.filter { reach.touches(boxes[$0]) }
            }
            guard !paper.isEmpty else { return Kept(path: paths[i], inkAbove: inkAbove) }
            let cut = CGMutablePath()
            for j in paper { cut.addPath(paths[j]) }
            return Kept(path: paths[i].subtracting(cut, using: .winding), inkAbove: inkAbove)
        }
    }

    /// Where a path is: which cells of a grid its outline passes through, and
    /// whether the cells it does not pass through are inside it.
    ///
    /// A cell the outline misses is all inside or all outside, and so is any
    /// block of such cells, so a box lying in one is settled by a single point.
    final class Reach {
        private let path: CGPath
        private let box: CGRect
        private let side = 96
        private var outline: [Bool]
        private var inside: [Bool?]

        init(of path: CGPath, box: CGRect) {
            self.path = path
            self.box = box
            outline = [Bool](repeating: false, count: side * side)
            inside = [Bool?](repeating: nil, count: side * side)
            // Every segment marks the cells its control points span, which is
            // never less than the cells the curve itself crosses.
            var cur = CGPoint.zero, start = CGPoint.zero
            path.applyWithBlock { e in
                let p = e.pointee.points
                switch e.pointee.type {
                case .moveToPoint: cur = p[0]; start = cur
                case .addLineToPoint: self.mark(cur, p[0]); cur = p[0]
                case .addQuadCurveToPoint: self.mark(cur, p[0], p[1]); cur = p[1]
                case .addCurveToPoint: self.mark(cur, p[0], p[1], p[2]); cur = p[2]
                case .closeSubpath: self.mark(cur, start); cur = start
                @unknown default: break
                }
            }
        }

        private func mark(_ pts: CGPoint...) {
            var lo = pts[0], hi = pts[0]
            for q in pts.dropFirst() {
                lo = CGPoint(x: min(lo.x, q.x), y: min(lo.y, q.y))
                hi = CGPoint(x: max(hi.x, q.x), y: max(hi.y, q.y))
            }
            let (xs, ys) = cells(CGRect(x: lo.x - 0.01, y: lo.y - 0.01,
                                        width: hi.x - lo.x + 0.02, height: hi.y - lo.y + 0.02))
            for y in ys { for x in xs { outline[y * side + x] = true } }
        }

        /// The block of cells a rectangle lies over, clamped to the grid.
        private func cells(_ r: CGRect) -> (ClosedRange<Int>, ClosedRange<Int>) {
            let cw = max(box.width / CGFloat(side), 1e-6), ch = max(box.height / CGFloat(side), 1e-6)
            func cell(_ v: CGFloat, _ origin: CGFloat, _ size: CGFloat) -> Int {
                min(side - 1, max(0, Int(((v - origin) / size).rounded(.down))))
            }
            let x0 = cell(r.minX, box.minX, cw), x1 = max(x0, cell(r.maxX, box.minX, cw))
            let y0 = cell(r.minY, box.minY, ch), y1 = max(y0, cell(r.maxY, box.minY, ch))
            return (x0...x1, y0...y1)
        }

        /// Could a shape with this box cut into the path or overlap it?
        func touches(_ other: CGRect) -> Bool {
            let r = other.intersection(box)
            guard !r.isNull else { return false }
            let (xs, ys) = cells(r)
            for y in ys { for x in xs where outline[y * side + x] { return true } }
            // Clear of the outline, so wholly in or wholly out: ask one cell.
            let cell = ys.lowerBound * side + xs.lowerBound
            if let known = inside[cell] { return known }
            let cw = box.width / CGFloat(side), ch = box.height / CGFloat(side)
            let centre = CGPoint(x: box.minX + (CGFloat(xs.lowerBound) + 0.5) * cw,
                                 y: box.minY + (CGFloat(ys.lowerBound) + 0.5) * ch)
            let answer = path.contains(centre, using: .winding)
            inside[cell] = answer
            return answer
        }
    }

    /// Raised once, read from every thread.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    /// Folds finished, counted from every thread at once.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var done = 0
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; done += 1; return done }
    }

    /// Each pair writes its own slot, so the threads never share one.
    struct UncheckedBuffer<T>: @unchecked Sendable { let base: UnsafeMutableBufferPointer<T> }

    /// Darker than mid grey is ink. Rec. 709 luma, which is what a screen
    /// shows and close enough to what a trace produced: its fills are pure
    /// black and pure white and never come near the line.
    static func isInk(_ color: Color) -> Bool {
        0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b < 0.5
    }

    /// The colour a layer paints with, or nil when it paints nothing.
    static func paintColor(_ l: Layer) -> Color? {
        for f in l.style.fills where f.opacity > 0 {
            switch f.paint {
            case .color(let c): return c.a > 0 ? c : nil
            case .gradient(let g): return g.stops.first?.color
            }
        }
        return nil
    }

    /// What a layer would contribute, in its own space. Text is outlined here
    /// rather than on the page, so preparing changes nothing.
    static func geometry(_ l: Layer) -> CGPath? {
        if case .text(let run) = l.kind {
            return TextOutline.path(run, in: CGRect(origin: .zero, size: l.frame.size))
        }
        return Compose.resolvedPath(l)
    }

    /// The colour a layer paints with; for text, the run's colour when the
    /// style has none, which is what the canvas falls back to.
    static func color(of l: Layer) -> Color? {
        if let c = paintColor(l) { return c }
        if case .text(let run) = l.kind { return run.color }
        return nil
    }

    /// Reads the selected layers, or the contents of a selected group, into
    /// pieces in painting order. Nothing on the page changes.
    public static func prepare(_ page: Page, _ ids: [String]) -> Result<Prepared, Refusal> {
        let wanted = Set(ids)
        let ordered = page.find(LayerQuery()).filter { wanted.contains($0) }
        guard !ordered.isEmpty else { return .failure(Refusal(why: "Select the shapes to punch out")) }

        // One walk for every selected layer and the container it sits in. Asking
        // the page for each one by id is a walk of the whole tree apiece, and a
        // Select All inside a traced coin is seven thousand of them.
        var found: [String: Layer] = [:], parentOf: [String: String?] = [:]
        func look(_ layers: [Layer], under parent: String?) {
            for l in layers {
                if wanted.contains(l.id) { found[l.id] = l; parentOf[l.id] = parent }
                switch l.kind {
                case .group(let k), .shapeGroup(let k, _): look(k, under: l.id)
                default: break
                }
            }
        }
        look(page.layers, under: nil)

        let parents = Set(ordered.map { parentOf[$0] ?? nil })
        guard parents.count == 1, let parent = parents.first else {
            return .failure(Refusal(why: "Punch Out works on shapes inside one artboard or group"))
        }

        var pieces: [(path: CGPath, ink: Bool)] = []
        var pictures = 0
        func gather(_ l: Layer, base: CGAffineTransform) {
            guard l.isVisible else { return }
            switch l.kind {
            case .group(let kids):
                for k in kids { gather(k, base: Compose.transform(l).concatenating(base)) }
            case .bitmap:
                pictures += 1
            default:
                guard let raw = geometry(l), let c = color(of: l) else { return }
                pieces.append((raw.transformed(by: Compose.transform(l).concatenating(base)), isInk(c)))
            }
        }
        for id in ordered { if let l = found[id] { gather(l, base: .identity) } }

        if pictures > 0 {
            return .failure(Refusal(why: "Punch Out works on shapes. Vectorize the picture first"))
        }
        // A light shape under everything is paper, not a hole in anything, and
        // the fold starts at the first dark one.
        while let first = pieces.first, !first.ink { pieces.removeFirst() }
        guard !pieces.isEmpty else {
            return .failure(Refusal(why: "Nothing dark to keep — Punch Out needs at least one dark shape"))
        }
        return .success(Prepared(pieces: pieces, parent: parent, originals: ordered))
    }
}

extension Page {

    /// Puts the folded path down in place of the pieces: one plain shape,
    /// filled black, where the topmost of them was.
    @discardableResult
    public mutating func apply(_ prepared: PunchOut.Prepared, folded: CGPath?) -> PunchOut.Outcome {
        guard let folded, !folded.isEmpty else { return .refused("Those shapes have no area") }
        // The pieces may have gone while the fold ran. Better to say so than to
        // put a shape down beside whatever replaced them.
        let going = Set(prepared.originals)
        guard countLayers(in: going) == going.count else {
            return .refused("The shapes changed while Punch Out was running. Run it again")
        }
        let box = folded.boundingBoxOfPath
        guard box.width > 0, box.height > 0 else { return .refused("Those shapes have no area") }

        removeLayers(going)

        var made = Layer(kind: .path(folded.transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY)),
                                     closed: true))
        made.name = "Punch Out"
        made.frame = box
        made.style.fills = [Fill(paint: .color(.black))]
        insertLayer(made, parent: prepared.parent, index: children(of: prepared.parent).count)
        return .made(id: made.id, inks: prepared.inks, holes: prepared.holes)
    }

    /// How many of these ids are on the page, in one walk.
    func countLayers(in ids: Set<String>) -> Int {
        func count(_ layers: [Layer]) -> Int {
            layers.reduce(0) { n, l in
                var n = n + (ids.contains(l.id) ? 1 : 0)
                switch l.kind {
                case .group(let k), .shapeGroup(let k, _): n += count(k)
                default: break
                }
                return n
            }
        }
        return count(layers)
    }

    /// Takes every one of these layers off the page in one walk. `removeLayer`
    /// searches the tree and rebuilds the path down to each layer it removes.
    mutating func removeLayers(_ ids: Set<String>) {
        func strip(_ layers: [Layer]) -> [Layer] {
            var out: [Layer] = []
            out.reserveCapacity(layers.count)
            for var l in layers where !ids.contains(l.id) {
                switch l.kind {
                case .group(let k): l.kind = .group(strip(k))
                case .shapeGroup(let k, let rule): l.kind = .shapeGroup(strip(k), rule)
                default: break
                }
                out.append(l)
            }
            return out
        }
        layers = strip(layers)
    }

    /// All three steps, blocking. For the document API and tests; the app
    /// folds on another thread.
    @discardableResult
    public mutating func punchOut(_ ids: [String]) -> PunchOut.Outcome {
        switch PunchOut.prepare(self, ids) {
        case .failure(let r): return .refused(r.why)
        case .success(let prepared):
            guard let folded = try? prepared.fold() else { return .refused("Punch Out was stopped") }
            return apply(prepared, folded: folded)
        }
    }
}
