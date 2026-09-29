import CoreGraphics
import Foundation
import Testing
@testable import SkechworksCore

private func disc(_ rect: CGRect, hex: String, name: String = "") -> Layer {
    var l = Layer(kind: .path(CGPath(ellipseIn: CGRect(origin: .zero, size: rect.size), transform: nil), closed: true))
    l.frame = rect
    l.name = name
    l.style.fills = [Fill(paint: .color(Color(hex: hex)!))]
    return l
}

private func box(_ rect: CGRect, hex: String, name: String = "") -> Layer {
    var l = Layer(kind: .path(CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), closed: true))
    l.frame = rect
    l.name = name
    l.style.fills = [Fill(paint: .color(Color(hex: hex)!))]
    return l
}

/// The traced coin: a black disc, a white letter on it, the letter's black
/// counter on that. Punch Out has to give one shape that is ink on the disc,
/// nothing where the letter is, and ink again inside the counter.
@Test func punchOutFoldsDarkAndLightInPaintingOrder() throws {
    var page = Page(name: "P")
    let plate = disc(CGRect(x: 0, y: 0, width: 200, height: 200), hex: "#000000", name: "disc")
    let letter = box(CGRect(x: 50, y: 50, width: 100, height: 100), hex: "#ffffff", name: "O")
    let counter = box(CGRect(x: 80, y: 80, width: 40, height: 40), hex: "#000000", name: "counter")
    page.layers = [plate, letter, counter]

    let outcome = page.punchOut([plate.id, letter.id, counter.id])
    guard case .made(let id, let inks, let holes) = outcome else {
        Issue.record("refused: \(outcome)"); return
    }
    #expect(inks == 2)
    #expect(holes == 1)
    #expect(page.layers.count == 1)

    let made = try #require(page.layer(id))
    #expect(made.name == "Punch Out")
    guard case .path = made.kind else { Issue.record("not one plain path"); return }

    let p = try #require(Compose.resolvedPath(made)).transformed(by: Compose.transform(made))
    #expect(p.contains(CGPoint(x: 100, y: 10)))     // on the disc
    #expect(!p.contains(CGPoint(x: 60, y: 60)))     // inside the letter: a hole
    #expect(p.contains(CGPoint(x: 100, y: 100)))    // the counter is ink again
}

/// The pieces are usually one group, straight from Vectorize. Selecting the
/// group is enough, and a white ground under everything is dropped rather
/// than made the base.
@Test func punchOutTakesAGroupAndDropsThePaperUnderneath() throws {
    var page = Page(name: "P")
    let paper = box(CGRect(x: 0, y: 0, width: 300, height: 300), hex: "#fefefe", name: "backdrop")
    let plate = disc(CGRect(x: 50, y: 50, width: 200, height: 200), hex: "#000000", name: "disc")
    let letter = box(CGRect(x: 100, y: 100, width: 100, height: 100), hex: "#ffffff", name: "O")
    var group = Layer(kind: .group([paper, plate, letter]))
    group.frame = CGRect(x: 20, y: 30, width: 300, height: 300)
    page.layers = [group]

    guard case .made(let id, let inks, let holes) = page.punchOut([group.id]) else {
        Issue.record("refused"); return
    }
    #expect(inks == 1)
    #expect(holes == 1)
    let made = try #require(page.layer(id))
    // The shape sits where the disc was, in page space, and the group is gone.
    #expect(made.frame.integral == CGRect(x: 70, y: 80, width: 200, height: 200))
    #expect(page.layers.count == 1)
    let p = try #require(Compose.resolvedPath(made)).transformed(by: Compose.transform(made))
    #expect(p.contains(CGPoint(x: 80, y: 180)))      // on the disc
    #expect(!p.contains(CGPoint(x: 170, y: 180)))    // the letter is a hole
}

@Test func punchOutOutlinesTextAndRefusesWithNothingDark() throws {
    var page = Page(name: "P")
    let only = box(CGRect(x: 0, y: 0, width: 50, height: 50), hex: "#ffffff")
    page.layers = [only]
    #expect(page.punchOut([only.id]) == .refused("Nothing dark to keep — Punch Out needs at least one dark shape"))

    var page2 = Page(name: "P2")
    let plate = disc(CGRect(x: 0, y: 0, width: 200, height: 200), hex: "#000000", name: "disc")
    var run = TextRun()
    run.string = "O"
    run.fontSize = 60
    run.color = Color(hex: "#ffffff")!
    var word = Layer(kind: .text(run))
    word.frame = CGRect(x: 60, y: 60, width: 80, height: 80)
    word.name = "word"
    page2.layers = [plate, word]

    guard case .made(let id, _, let holes) = page2.punchOut([plate.id, word.id]) else {
        Issue.record("refused"); return
    }
    #expect(holes == 1)
    let made = try #require(page2.layer(id))
    let p = try #require(Compose.resolvedPath(made)).transformed(by: Compose.transform(made))
    #expect(p.contains(CGPoint(x: 100, y: 10)))
    // Somewhere inside the O's stroke there is a hole; the disc is solid otherwise.
    let holed = (0..<80).contains { i in !p.contains(CGPoint(x: 60 + CGFloat(i), y: 100)) }
    #expect(holed, "the outlined text cut nothing")
}

/// The old chain fold, kept as the answer the bracket has to match.
private func chainFold(_ pieces: [(path: CGPath, ink: Bool)]) -> CGPath? {
    var acc: CGPath?
    for piece in pieces {
        let p = piece.path.normalized(using: .winding)
        if piece.ink { acc = acc.map { $0.union(p, using: .winding) } ?? p }
        else { acc = acc?.subtracting(p, using: .winding) }
    }
    return acc
}

/// Blobs scattered and stacked like a traced drawing's fur: dark and light,
/// mostly small, overlapping their neighbours in the stack.
private func furStack(_ count: Int, seed: UInt64) -> [(path: CGPath, ink: Bool)] {
    var rng = seed
    func next() -> CGFloat { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(rng >> 33) / CGFloat(1 << 31) }
    var out: [(path: CGPath, ink: Bool)] = [(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 400, height: 400), transform: nil), true)]
    for i in 1..<count {
        let r = 4 + next() * 18
        let c = CGPoint(x: 20 + next() * 360, y: 20 + next() * 360)
        let path = CGMutablePath()
        let spikes = 5 + Int(next() * 4)
        for k in 0..<(spikes * 2) {
            let a = CGFloat(k) / CGFloat(spikes * 2) * 2 * .pi
            let rr = k % 2 == 0 ? r : r * (0.4 + next() * 0.4)
            let p = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        out.append((path, i % 3 != 0))
    }
    return out
}

private func coverage(_ path: CGPath?) -> [Bool] {
    let side = 200
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setShouldAntialias(false)
    ctx.scaleBy(x: 0.5, y: 0.5)
    if let path { ctx.addPath(path); ctx.setFillColor(gray: 1, alpha: 1); ctx.fillPath() }
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return (0..<(side * side)).map { data[$0] > 127 }
}

@Test func theBracketFoldPaintsWhatTheChainDid() throws {
    for seed in [1, 7, 42] as [UInt64] {
        let pieces = furStack(120, seed: seed)
        let prepared = PunchOut.Prepared(pieces: pieces, parent: nil, originals: [])
        let fast = coverage(try prepared.fold())
        let slow = coverage(chainFold(pieces))
        let differ = zip(fast, slow).filter { $0 != $1 }.count
        #expect(differ <= fast.count / 2000, "seed \(seed): \(differ) pixels differ")
        #expect(fast.contains(true) && fast.contains(false))
    }
}

@Test func theBracketFoldCountsItsProgress() throws {
    let prepared = PunchOut.Prepared(pieces: furStack(50, seed: 3), parent: nil, originals: [])
    final class Seen: @unchecked Sendable { var last = (0, 0); let lock = NSLock() }
    let seen = Seen()
    _ = try prepared.fold { done, total in seen.lock.lock(); if done > seen.last.0 { seen.last = (done, total) }; seen.lock.unlock() }
    #expect(seen.last == (49, 49))
}
