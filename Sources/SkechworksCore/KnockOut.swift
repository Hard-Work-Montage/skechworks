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
/// with no edge at all. A patch is kept only when most of its edge is hard.
///
/// What comes back is outlines, one erase per patch, for the same reason the
/// wand's are: an erase here is a stored decision that saves, reopens and undoes.
public enum KnockOut {

    public static let defaultTolerance = 20.0

    /// The patches of `color` in `image` as rings, one list per patch, outside
    /// edge first and then its holes. In image pixels, y down.
    ///
    /// `color` does not have to be exact. Whoever asked usually said "the gold"
    /// and never saw the pixels, so the hue is moved to the strongest colour in
    /// the picture near the one given before anything is matched.
    ///
    /// `everywhere` skips the edge test, for flat artwork where every patch of
    /// the colour really is meant.
    public static func rings(in image: CGImage, color: Color,
                             tolerance: Double = defaultTolerance,
                             everywhere: Bool = false) -> [[[CGPoint]]] {
        guard let mask = mask(in: image, color: color, tolerance: tolerance,
                              everywhere: everywhere) else { return [] }
        return split(mask.bits, w: mask.w, h: mask.h)
    }

    /// The erase as flags, one per pixel.
    static func mask(in image: CGImage, color: Color, tolerance: Double,
                     everywhere: Bool) -> (bits: [Bool], w: Int, h: Int)? {
        let w = image.width, h = image.height, n = w * h
        guard w > 2, h > 2 else { return nil }

        var bytes = [UInt8](repeating: 0, count: n * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        var hue = [Float](repeating: 0, count: n)
        var sat = [Float](repeating: 0, count: n)
        var val = [Float](repeating: 0, count: n)
        // Already erased, or never there. Never a match and always a hard edge.
        var clear = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let a = bytes[i * 4 + 3]
            if a < 8 { clear[i] = true; continue }
            let k = 255 / Float(a)
            let (hh, ss, vv) = hsv(Float(bytes[i * 4]) * k / 255,
                                   Float(bytes[i * 4 + 1]) * k / 255,
                                   Float(bytes[i * 4 + 2]) * k / 255)
            hue[i] = hh; sat[i] = ss; val[i] = vv
        }

        let target = hsv(Float(color.r), Float(color.g), Float(color.b))
        let chromatic = target.s >= 0.2
        let half = Float(2 + tolerance * 0.25)
        var centre = target.h
        if chromatic { centre = strongestHue(near: target.h, hue: hue, sat: sat, val: val, clear: clear) }
        func apart(_ a: Float) -> Float { let d = abs(a - centre); return d > 180 ? 360 - d : d }

        // The paint itself.
        let sMin = min(0.45, target.s * 0.6), vMin = min(0.45, target.v * 0.6)
        let vSpan = Float(0.08 + tolerance * 0.006)
        func strict(_ i: Int) -> Bool {
            if clear[i] { return false }
            if chromatic { return apart(hue[i]) <= half && sat[i] >= sMin && val[i] >= vMin }
            return sat[i] <= 0.18 && abs(val[i] - target.v) <= vSpan
        }
        // The same colour carrying on past the patch: what a soft edge is made of.
        func carriesOn(_ i: Int) -> Bool {
            if clear[i] { return false }
            if chromatic { return val[i] > 0.3 && sat[i] >= 0.3 && apart(hue[i]) <= half + 25 }
            return sat[i] <= 0.3 && abs(val[i] - target.v) <= 0.35
        }
        // Its own shading and anti-aliasing, darker and paler than the paint.
        func fringe(_ i: Int) -> Bool {
            if clear[i] { return false }
            if chromatic { return apart(hue[i]) <= half + 16 && sat[i] >= 0.2 && val[i] >= 0.2 }
            return sat[i] <= 0.25 && abs(val[i] - target.v) <= vSpan + 0.1
        }

        var match = [Bool](repeating: false, count: n)
        for i in 0..<n { match[i] = strict(i) }

        func neighbours(_ j: Int) -> [Int] {
            let x = j % w, y = j / w
            return [x > 0 ? j - 1 : -1, x < w - 1 ? j + 1 : -1,
                    y > 0 ? j - w : -1, y < h - 1 ? j + w : -1].filter { $0 >= 0 }
        }

        // Keep the patches with a hard edge. A stray grass blade is small, so
        // size counts too, scaled so a bigger picture doesn't let more through.
        var keep = [Bool](repeating: false, count: n)
        var seen = [Bool](repeating: false, count: n)
        var edgeMark = [Int32](repeating: 0, count: n)
        let minSize = everywhere ? max(4, n / 100_000) : max(30, n / 3000)
        let reach = max(4, w / 400)
        var patch: Int32 = 0
        var stack: [Int] = []
        for i in 0..<n where match[i] && !seen[i] {
            patch += 1
            seen[i] = true
            stack = [i]
            var members: [Int] = []
            var edge = 0, hard = 0
            while let j = stack.popLast() {
                members.append(j)
                let x = j % w, y = j / w
                for k in neighbours(j) {
                    if match[k] {
                        if !seen[k] { seen[k] = true; stack.append(k) }
                        continue
                    }
                    guard edgeMark[k] != patch else { continue }
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
            if everywhere || (edge > 0 && Double(hard) / Double(edge) >= 0.6) {
                for j in members { keep[j] = true }
            }
        }
        guard keep.contains(true) else { return nil }

        // Grow into the colour's own fringe, so the bevel goes with the rim
        // instead of staying behind as a brown hairline round it.
        var frontier = (0..<n).filter { keep[$0] }
        for _ in 0..<max(3, w / 250) {
            var next: [Int] = []
            for j in frontier {
                for k in neighbours(j) where !keep[k] && fringe(k) {
                    keep[k] = true
                    next.append(k)
                }
            }
            if next.isEmpty { break }
            frontier = next
        }

        // Fill the small holes. On textured metal these are the cracks in the
        // texture, and every one left behind is a speck to delete by hand.
        let maxHole = max(16, n / 8000)
        var visited = [Bool](repeating: false, count: n)
        for i in 0..<n where !keep[i] && !visited[i] {
            visited[i] = true
            stack = [i]
            var members: [Int] = []
            var open = false
            while let j = stack.popLast() {
                members.append(j)
                let x = j % w, y = j / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { open = true }
                for k in neighbours(j) where !keep[k] && !visited[k] {
                    visited[k] = true
                    stack.append(k)
                }
            }
            if !open && members.count <= maxHole { for j in members { keep[j] = true } }
        }

        // One more pixel all round. The outline an erase stores runs through
        // the edge pixels' corners, and without this a half-pixel of the old
        // colour shows round everything.
        let before = keep
        for j in 0..<n where !before[j] && neighbours(j).contains(where: { before[$0] }) {
            keep[j] = true
        }
        return (keep, w, h)
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

    /// The most common strong hue within 15° of `near`. "Gold" arrives as
    /// #FFD700 as often as anything, and the gold on a real coin sits ten
    /// degrees redder than that.
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

    /// Flags to rings, one list per connected patch. Each patch is traced in
    /// its own box, so twenty letters cost twenty small pictures rather than
    /// twenty whole ones.
    static func split(_ bits: [Bool], w: Int, h: Int) -> [[[CGPoint]]] {
        var label = [Int32](repeating: 0, count: w * h)
        var next: Int32 = 0
        var out: [[[CGPoint]]] = []
        var stack: [Int] = []
        for i in 0..<(w * h) where bits[i] && label[i] == 0 {
            next += 1
            let mine = next
            label[i] = mine
            stack = [i]
            var minX = w, minY = h, maxX = 0, maxY = 0
            while let j = stack.popLast() {
                let x = j % w, y = j / w
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for k in [x > 0 ? j - 1 : -1, x < w - 1 ? j + 1 : -1,
                          y > 0 ? j - w : -1, y < h - 1 ? j + w : -1]
                where k >= 0 && bits[k] && label[k] == 0 {
                    label[k] = mine
                    stack.append(k)
                }
            }
            // A pixel of margin, so the box's edge is outside the patch.
            let bx = minX - 1, by = minY - 1
            let bw = maxX - minX + 3, bh = maxY - minY + 3
            var local = [Bool](repeating: false, count: bw * bh)
            for y in minY...maxY {
                for x in minX...maxX where label[y * w + x] == mine {
                    local[(y - by) * bw + (x - bx)] = true
                }
            }
            guard let rings = Wand.rings(bits: local, w: bw, h: bh) else { continue }
            out.append(rings.map { $0.map { CGPoint(x: $0.x + CGFloat(bx), y: $0.y + CGFloat(by)) } })
        }
        return out
    }
}
