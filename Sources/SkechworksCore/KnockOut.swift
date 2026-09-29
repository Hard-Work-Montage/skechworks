import CoreGraphics
import Foundation

/// Erasing every patch of one colour from a picture at once.
///
/// The case this is for is a colour coin: a painted picture with gold rims and
/// gold lettering, where the gold has to go so the coin's own metal shows
/// through. The gold is not one colour. It is textured, shaded and bevelled, so
/// the wand picks up a crack at a time, and vectorizing it leaves a hundred
/// stray fills round every rim.
///
/// Two tests do it. The first is the colour: close in hue, strong enough in
/// saturation and brightness to be the paint rather than a shadow on it. That
/// alone also catches a sunset, because a sunset is gold too. The second is the
/// edge: a rim or a letter is PAINTED ON, so where it stops there is an outline,
/// or white, or a different colour entirely. Gold in a sky fades into orange
/// with no edge at all.
///
/// Every patch that passes a loose version of the edge test comes back as a
/// candidate, with how outlined it is. The erase takes the well-outlined ones on
/// its own; a model looking at the picture can pick instead, because a lit cloud
/// against blue sky is outlined enough to fool a number and not a look.
///
/// What comes back is outlines, one erase per patch, for the same reason the
/// wand's are: an erase here is a stored decision that saves, reopens and undoes.
public enum KnockOut {

    public static let defaultTolerance = 20.0

    /// How much of a patch's edge has to be a hard stop for it to be erased
    /// without anyone choosing. Rims and lettering on real coins measure 85 to
    /// 99 percent; a lit cloud and clumps of sunlit grass, 63 to 76.
    public static let outlinedEnough = 0.8

    /// Below this a patch isn't offered at all: it is part of the scenery.
    static let worthOffering = 0.5

    /// One patch of the colour.
    public struct Patch: Sendable {
        /// Each piece as rings, outside edge first, then its holes. Most
        /// patches are one piece; a letter "i" is two. Image pixels, y down.
        public var pieces: [[[CGPoint]]]
        /// Image pixels, y down.
        public var box: CGRect
        public var area: Int
        /// The share of its edge that is a hard stop, 0 to 1.
        public var outlined: Double
    }

    /// The patches of `color` in `image`, biggest first, at most `limit` of them.
    ///
    /// `exact` means the colour was sampled from the picture, by the wand, and
    /// is used as it is. Otherwise it is a guess from a name, and the hue is
    /// moved to the strongest colour in the picture near it first: "gold"
    /// arrives as #FFD700 and the gold on a real coin sits ten degrees redder.
    ///
    /// `everywhere` drops the edge test, for flat artwork where every patch of
    /// the colour really is meant.
    public static func patches(in image: CGImage, color: Color,
                               tolerance: Double = defaultTolerance,
                               exact: Bool = false, everywhere: Bool = false,
                               limit: Int = 40) -> [Patch] {
        guard let found = labels(in: image, color: color, tolerance: tolerance,
                                 exact: exact, everywhere: everywhere) else { return [] }
        let order = found.outlined.indices.sorted { found.area[$0] > found.area[$1] }
        var out: [Patch] = []
        for k in order.prefix(limit) {
            let pieces = split(found.label.map { $0 == Int32(k + 1) }, w: found.w, h: found.h,
                               within: found.box[k])
            guard !pieces.isEmpty else { continue }
            out.append(Patch(pieces: pieces, box: found.box[k], area: found.area[k],
                             outlined: everywhere ? 1 : found.outlined[k]))
        }
        return out
    }

    /// The patches the erase takes on its own: the outlined ones.
    public static func rings(in image: CGImage, color: Color,
                             tolerance: Double = defaultTolerance,
                             exact: Bool = false, everywhere: Bool = false) -> [[[CGPoint]]] {
        patches(in: image, color: color, tolerance: tolerance, exact: exact,
                everywhere: everywhere, limit: .max)
            .filter { $0.outlined >= outlinedEnough }
            .flatMap(\.pieces)
    }

    /// The erase as flags, one per pixel: what `rings` would take.
    static func mask(in image: CGImage, color: Color, tolerance: Double,
                     everywhere: Bool, exact: Bool = false) -> (bits: [Bool], w: Int, h: Int)? {
        guard let found = labels(in: image, color: color, tolerance: tolerance,
                                 exact: exact, everywhere: everywhere) else { return nil }
        let taken = found.outlined.map { everywhere || $0 >= outlinedEnough }
        let bits = found.label.map { $0 > 0 && taken[Int($0) - 1] }
        guard bits.contains(true) else { return nil }
        return (bits, found.w, found.h)
    }

    /// Every candidate patch as a number on each pixel, 0 for none, with each
    /// patch's edge score, size and box. Patches keep their own numbers through
    /// the clean-up, so a clump of grass that grows into the letter beside it
    /// is still its own patch to leave out.
    static func labels(in image: CGImage, color: Color, tolerance: Double,
                       exact: Bool, everywhere: Bool)
        -> (label: [Int32], outlined: [Double], area: [Int], box: [CGRect], w: Int, h: Int)? {
        guard let px = Pixels(image) else { return nil }
        let w = px.w, h = px.h, n = w * h
        let hue = px.hue, sat = px.sat, val = px.val, clear = px.clear

        let target = hsv(Float(color.r), Float(color.g), Float(color.b))
        let chromatic = target.s >= 0.2
        let half = Float(2 + tolerance * 0.25)
        var centre = target.h
        if chromatic && !exact {
            centre = strongestHue(near: target.h, hue: hue, sat: sat, val: val, clear: clear)
        }
        func apart(_ a: Float) -> Float { let d = abs(a - centre); return d > 180 ? 360 - d : d }

        // The paint itself. A sampled colour says how strong this picture's
        // own version of it is, which a name can't: antique gold is half as
        // saturated as leaflet gold, and a cut-off for one misses the other.
        let loosen = Float(tolerance - defaultTolerance) * 0.01
        let sMin = exact ? max(0.1, target.s * 0.6 - loosen) : min(0.45, target.s * 0.6)
        let vMin = exact ? max(0.15, target.v * 0.55 - loosen) : min(0.45, target.v * 0.6)
        let vSpan = Float(0.08 + tolerance * 0.006)
        func strict(_ i: Int) -> Bool {
            if clear[i] { return false }
            if chromatic { return apart(hue[i]) <= half && sat[i] >= sMin && val[i] >= vMin }
            return sat[i] <= 0.18 && abs(val[i] - target.v) <= vSpan
        }
        // The same colour carrying on past the patch: what a soft edge is made of.
        func carriesOn(_ i: Int) -> Bool {
            if clear[i] { return false }
            if chromatic { return val[i] > 0.3 && sat[i] >= min(0.3, sMin) && apart(hue[i]) <= half + 25 }
            return sat[i] <= 0.3 && abs(val[i] - target.v) <= 0.35
        }
        // Its own shading and anti-aliasing, darker and paler than the paint.
        func fringe(_ i: Int) -> Bool {
            if clear[i] { return false }
            if chromatic { return apart(hue[i]) <= half + 16 && sat[i] >= min(0.2, sMin) && val[i] >= 0.2 }
            return sat[i] <= 0.25 && abs(val[i] - target.v) <= vSpan + 0.1
        }

        var match = [Bool](repeating: false, count: n)
        for i in 0..<n { match[i] = strict(i) }

        var label = [Int32](repeating: 0, count: n)
        var outlined: [Double] = []
        var seen = [Bool](repeating: false, count: n)
        var edgeMark = [Int32](repeating: 0, count: n)
        let minSize = everywhere ? max(4, n / 100_000) : max(30, n / 3000)
        let reach = max(4, w / 400)
        var patch: Int32 = 0
        var stack: [Int] = []
        var members: [Int] = []
        for i in 0..<n where match[i] && !seen[i] {
            patch += 1
            seen[i] = true
            stack = [i]
            members.removeAll(keepingCapacity: true)
            var edge = 0, hard = 0
            while let j = stack.popLast() {
                members.append(j)
                let x = j % w, y = j / w
                forEachNeighbour(j, w: w, h: h) { k in
                    if match[k] {
                        if !seen[k] { seen[k] = true; stack.append(k) }
                        return
                    }
                    guard edgeMark[k] != patch else { return }
                    edgeMark[k] = patch
                    edge += 1
                    // Look a few pixels outward. Anything that isn't the
                    // colour carrying on means the patch stopped at a line.
                    let sx = k % w - x, sy = k / w - y
                    for t in 0..<reach {
                        let xx = k % w + sx * t, yy = k / w + sy * t
                        guard xx >= 0, yy >= 0, xx < w, yy < h else { hard += 1; break }
                        if !carriesOn(yy * w + xx) { hard += 1; break }
                    }
                }
            }
            guard members.count >= minSize else { continue }
            let score = edge > 0 ? Double(hard) / Double(edge) : 0
            guard everywhere || score >= worthOffering else { continue }
            outlined.append(score)
            let mine = Int32(outlined.count)
            for j in members { label[j] = mine }
        }
        guard !outlined.isEmpty else { return nil }

        // Grow into the colour's own fringe, so the bevel goes with the rim
        // instead of staying behind as a brown hairline round it. Each patch
        // grows as itself and never into another.
        var frontier = (0..<n).filter { label[$0] > 0 }
        for _ in 0..<max(3, w / 250) {
            var next: [Int] = []
            for j in frontier {
                forEachNeighbour(j, w: w, h: h) { k in
                    if label[k] == 0 && fringe(k) { label[k] = label[j]; next.append(k) }
                }
            }
            if next.isEmpty { break }
            frontier = next
        }

        // Fill the cracks. On textured metal every one left behind is a speck
        // to delete by hand. Only thin ones: the hole in a letter "a" is a
        // blob of whatever is behind the letter, and has to stay.
        let maxHole = max(16, n / 8000)
        var visited = [Bool](repeating: false, count: n)
        for i in 0..<n where label[i] == 0 && !visited[i] {
            visited[i] = true
            stack = [i]
            members.removeAll(keepingCapacity: true)
            var open = false
            var around: Int32 = 0
            var minX = w, minY = h, maxX = 0, maxY = 0
            while let j = stack.popLast() {
                members.append(j)
                let x = j % w, y = j / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { open = true }
                forEachNeighbour(j, w: w, h: h) { k in
                    if label[k] > 0 { around = label[k]; return }
                    if !visited[k] { visited[k] = true; stack.append(k) }
                }
            }
            let long = max(maxX - minX, maxY - minY) + 1
            let thin = members.count <= 12 || members.count <= 3 * long
            if !open && around > 0 && members.count <= maxHole && thin {
                for j in members { label[j] = around }
            }
        }

        // One more pixel all round. The outline an erase stores runs through
        // the edge pixels' corners, and without this a half-pixel of the old
        // colour shows round everything.
        let before = label
        for j in 0..<n where before[j] == 0 {
            forEachNeighbour(j, w: w, h: h) { k in
                if label[j] == 0 && before[k] > 0 { label[j] = before[k] }
            }
        }

        var area = [Int](repeating: 0, count: outlined.count)
        var lo = [(Int, Int)](repeating: (w, h), count: outlined.count)
        var hi = [(Int, Int)](repeating: (0, 0), count: outlined.count)
        for i in 0..<n where label[i] > 0 {
            let k = Int(label[i]) - 1, x = i % w, y = i / w
            area[k] += 1
            lo[k] = (min(lo[k].0, x), min(lo[k].1, y))
            hi[k] = (max(hi[k].0, x), max(hi[k].1, y))
        }
        let box = outlined.indices.map {
            CGRect(x: lo[$0].0, y: lo[$0].1, width: hi[$0].0 - lo[$0].0 + 1, height: hi[$0].1 - lo[$0].1 + 1)
        }
        return (label, outlined, area, box, w, h)
    }

    /// Flags to rings, one list per connected area. Each area is traced in its
    /// own box, so twenty letters cost twenty small pictures rather than twenty
    /// whole ones.
    static func split(_ bits: [Bool], w: Int, h: Int, within: CGRect? = nil) -> [[[CGPoint]]] {
        var label = [Int32](repeating: 0, count: w * h)
        var next: Int32 = 0
        var out: [[[CGPoint]]] = []
        var stack: [Int] = []
        let x0 = within.map { max(0, Int($0.minX)) } ?? 0
        let y0 = within.map { max(0, Int($0.minY)) } ?? 0
        let x1 = within.map { min(w, Int($0.maxX)) } ?? w
        let y1 = within.map { min(h, Int($0.maxY)) } ?? h
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y * w + x
                guard bits[i] && label[i] == 0 else { continue }
                next += 1
                let mine = next
                label[i] = mine
                stack = [i]
                var minX = w, minY = h, maxX = 0, maxY = 0
                while let j = stack.popLast() {
                    let jx = j % w, jy = j / w
                    minX = min(minX, jx); maxX = max(maxX, jx)
                    minY = min(minY, jy); maxY = max(maxY, jy)
                    forEachNeighbour(j, w: w, h: h) { k in
                        if bits[k] && label[k] == 0 { label[k] = mine; stack.append(k) }
                    }
                }
                // A pixel of margin, so the box's edge is outside the area.
                let bx = minX - 1, by = minY - 1
                let bw = maxX - minX + 3, bh = maxY - minY + 3
                var local = [Bool](repeating: false, count: bw * bh)
                for yy in minY...maxY {
                    for xx in minX...maxX where label[yy * w + xx] == mine {
                        local[(yy - by) * bw + (xx - bx)] = true
                    }
                }
                guard let rings = Wand.rings(bits: local, w: bw, h: bh) else { continue }
                out.append(rings.map { $0.map { CGPoint(x: $0.x + CGFloat(bx), y: $0.y + CGFloat(by)) } })
            }
        }
        return out
    }

    @inline(__always)
    static func forEachNeighbour(_ j: Int, w: Int, h: Int, _ body: (Int) -> Void) {
        let x = j % w
        if x > 0 { body(j - 1) }
        if x < w - 1 { body(j + 1) }
        if j >= w { body(j - w) }
        if j < w * (h - 1) { body(j + w) }
    }

    /// Hue, saturation and brightness, hue in degrees.
    static func hsv(_ r: Float, _ g: Float, _ b: Float) -> (h: Float, s: Float, v: Float) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h: Float = 0
        if d > 0 {
            if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    /// The most common strong hue within 15° of `near`.
    static func strongestHue(near: Float, hue: [Float], sat: [Float], val: [Float],
                             clear: [Bool]) -> Float {
        var bins = [Int](repeating: 0, count: 360)
        for i in hue.indices where !clear[i] && sat[i] >= 0.35 && val[i] >= 0.4 {
            bins[Int(hue[i]) % 360] += 1
        }
        var best = near, bestCount = 0
        for off in -15...15 {
            let c = (Int(near.rounded()) + off + 360) % 360
            let count = (-2...2).reduce(0) { $0 + bins[(c + $1 + 360) % 360] }
            if count > bestCount { bestCount = count; best = Float(c) }
        }
        return bestCount > 0 ? best : near
    }

    /// A picture read out as hue, saturation and brightness per pixel.
    struct Pixels {
        let w: Int, h: Int
        var hue: [Float], sat: [Float], val: [Float]
        /// Already erased, or never there.
        var clear: [Bool]

        init?(_ image: CGImage) {
            w = image.width; h = image.height
            let n = w * h
            guard w > 2, h > 2 else { return nil }
            var bytes = [UInt8](repeating: 0, count: n * 4)
            let (cw, ch) = (w, h)
            let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: cw, height: ch,
                                          bitsPerComponent: 8, bytesPerRow: cw * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: cw, height: ch))
                return true
            }
            guard drawn else { return nil }
            hue = [Float](repeating: 0, count: n)
            sat = [Float](repeating: 0, count: n)
            val = [Float](repeating: 0, count: n)
            clear = [Bool](repeating: false, count: n)
            for i in 0..<n {
                let a = bytes[i * 4 + 3]
                if a < 8 { clear[i] = true; continue }
                let k = 255 / Float(a)
                let (hh, ss, vv) = KnockOut.hsv(Float(bytes[i * 4]) * k / 255,
                                                Float(bytes[i * 4 + 1]) * k / 255,
                                                Float(bytes[i * 4 + 2]) * k / 255)
                hue[i] = hh; sat[i] = ss; val[i] = vv
            }
        }
    }
}
