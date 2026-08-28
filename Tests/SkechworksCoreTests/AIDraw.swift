import CoreGraphics
import Foundation
import Testing
@testable import SkechworksCore

// The two things a model needs before it can trace anything: a way to draw a
// curve, and a way to see how close it got.

// MARK: - Drawing a curve

@Test func pathDataBecomesALayerWhereItWasDrawn() {
    var page = Page(name: "P")
    let id = page.add({
        var s = AddSpec()
        s.kind = "path"
        s.d = "M 100 200 C 100 100 300 100 300 200 Z"
        return s
    }())
    let layer = try! #require(id.flatMap { page.layer($0) })
    // The frame comes from the data, not from a default size dropped in the
    // middle of the page — a model that measured a curve off an image means
    // exactly those coordinates.
    #expect(layer.frame.minX == 100)
    #expect(layer.frame.width == 200)
    guard case .path(let p, let closed) = layer.kind else { Issue.record("not a path"); return }
    #expect(closed)
    // Stored in the layer's own space, so the outline starts at its corner.
    #expect(p.boundingBoxOfPath.minX == 0)
    #expect(p.boundingBoxOfPath.minY == 0)
}

@Test func pathDataNeedsNoKindToBeUnderstood() {
    var page = Page(name: "P")
    let id = page.add({ var s = AddSpec(); s.d = "M 0 0 L 50 50"; return s }())
    let layer = try! #require(id.flatMap { page.layer($0) })
    // A default rectangle is a .path too, so the kind alone proves nothing. The
    // frame is the tell: data means these coordinates, not a 200×200 default.
    #expect(layer.frame == CGRect(x: 0, y: 0, width: 50, height: 50))
}

@Test func aPathWithNoDataIsRefusedRatherThanGuessed() {
    var page = Page(name: "P")
    #expect(page.add({ var s = AddSpec(); s.kind = "path"; return s }()) == nil)
    #expect(page.add({ var s = AddSpec(); s.kind = "path"; s.d = "  "; return s }()) == nil)
    #expect(page.layers.isEmpty)
}

@Test func givingASizeScalesTheDataToFitIt() {
    var page = Page(name: "P")
    let id = page.add({
        var s = AddSpec()
        s.d = "M 0 0 L 10 0 L 10 10 Z"
        s.width = 100; s.height = 50
        return s
    }())
    let layer = try! #require(id.flatMap { page.layer($0) })
    #expect(layer.frame.width == 100)
    #expect(layer.frame.height == 50)
    guard case .path(let p, _) = layer.kind else { Issue.record("not a path"); return }
    #expect(p.boundingBoxOfPath.width == 100)
}

@Test func aStrokeWithoutAFillDrawsHollow() {
    var page = Page(name: "P")
    let id = page.add({
        var s = AddSpec()
        s.d = "M 0 0 L 100 0"
        s.stroke = "#FF0000"; s.strokeWidth = 12
        return s
    }())
    let layer = try! #require(id.flatMap { page.layer($0) })
    #expect(layer.style.fills.isEmpty)
    #expect(layer.style.borders.first?.thickness == 12)
}

@Test func aFillAndAStrokeTogetherKeepBoth() {
    var page = Page(name: "P")
    let id = page.add({
        var s = AddSpec()
        s.d = "M 0 0 L 100 0 L 100 100 Z"
        s.fill = "#00FF00"; s.stroke = "#000000"; s.strokeWidth = 4
        return s
    }())
    let layer = try! #require(id.flatMap { page.layer($0) })
    #expect(layer.style.fills.count == 1)
    #expect(layer.style.borders.first?.thickness == 4)
}

@Test func theWholeThingArrivesAsACommand() {
    var page = Page(name: "P")
    let json = ##"{"commands":[{"op":"add","kind":"path","name":"Thumb","d":"M 10 10 C 10 40 60 40 60 10","stroke":"#111111","strokeWidth":8}]}"##
    _ = page.run(DocumentCommand.decodeList(Data(json.utf8)))
    let layer = try! #require(page.layers.first)
    #expect(layer.name == "Thumb")
    #expect(layer.style.borders.first?.thickness == 8)
}

// MARK: - Seeing how close it got

private func swatch(_ r: Double, _ g: Double, _ b: Double, side: Int = 64,
                    patch: CGRect? = nil) -> CGImage {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    ctx.fill(patch ?? CGRect(x: 0, y: 0, width: side, height: side))
    return ctx.makeImage()!
}

@Test func identicalRendersScorePerfectly() {
    let a = swatch(0.2, 0.4, 0.6)
    #expect(Compare.score(a, a) > 0.999)
}

@Test func blackAgainstWhiteScoresNothing() {
    #expect(Compare.score(swatch(0, 0, 0), swatch(1, 1, 1)) < 0.01)
}

@Test func aMistakeInOneCornerOnlyLightsThatCorner() {
    let clean = swatch(1, 1, 1)
    // Bottom-right eighth painted black.
    let smudged = swatch(0, 0, 0, patch: CGRect(x: 48, y: 48, width: 16, height: 16))
    let grid = Compare.errors(clean, smudged, cells: 4)
    // Row 0 is the top. CoreGraphics draws from the bottom, so the patch at y=48
    // lands in the TOP row of the image as it reads.
    #expect(grid[0][3] > 0.5)
    #expect(grid[2][1] < 0.01)
}

@Test func theWorstAreaComesBackInPageCoordinates() {
    let clean = swatch(1, 1, 1)
    let smudged = swatch(0, 0, 0, patch: CGRect(x: 48, y: 48, width: 16, height: 16))
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
    let spot = try! #require(Compare.hotspots(clean, smudged, in: bounds, cells: 4).first)
    #expect(spot.minX == 300)
    #expect(spot.minY == 0)
    #expect(spot.width == 100)
}

@Test func transparencyIsNotAFreePerfectScore() {
    // An empty page renders to nothing. Compared against real artwork it has to
    // score badly, or every trace passes by drawing nothing at all.
    let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let empty = ctx.makeImage()!
    #expect(Compare.score(empty, swatch(0, 0, 0)) < 0.05)
}

@Test func theReportReadsAsAGridAModelCanActdOn() {
    let clean = swatch(1, 1, 1)
    let smudged = swatch(0, 0, 0, patch: CGRect(x: 48, y: 48, width: 16, height: 16))
    let text = Compare.report(clean, against: smudged,
                              bounds: CGRect(x: 0, y: 0, width: 400, height: 400), cells: 4)
    #expect(text.contains("match "))
    #expect(text.contains("9 0 0 0") || text.contains("0 0 0 9"))
    #expect(text.contains("worst areas"))
}

@Test func aDrawingIsScoredAgainstThePictureItCameFrom() {
    // The loop end to end, without a model: draw the wrong thing, score it, draw
    // the right thing, score better.
    let reference = swatch(0, 0, 0, patch: CGRect(x: 0, y: 0, width: 32, height: 64))
    let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)

    var wrong = Page(name: "W")
    _ = wrong.add({ var s = AddSpec(); s.d = "M 40 0 L 64 0 L 64 64 L 40 64 Z"; s.fill = "#000000"; return s }())
    var right = Page(name: "R")
    _ = right.add({ var s = AddSpec(); s.d = "M 0 0 L 32 0 L 32 64 L 0 64 Z"; s.fill = "#000000"; return s }())

    let a = try! #require(Compare.render(wrong, bounds: bounds, matching: reference))
    let b = try! #require(Compare.render(right, bounds: bounds, matching: reference))
    #expect(Compare.score(b, reference) > Compare.score(a, reference))
    #expect(Compare.score(b, reference) > 0.9)
}

// MARK: - Knowing what kind of picture it is

private func canvas(_ side: Int = 128, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    draw(ctx)
    return ctx.makeImage()!
}

@Test func blackOnWhiteReadsAsLineArt() {
    let icon = canvas { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 20, width: 40, height: 88))
        ctx.fill(CGRect(x: 70, y: 20, width: 40, height: 88))
    }
    let stats = ImageStats.measure(icon)
    #expect(stats.verdict == .lineArt)
    #expect(stats.verdict.traceable)
    // The palette is the point: told, not guessed.
    #expect(stats.palette.map(\.hex).contains("#FFFFFF"))
    #expect(stats.palette.map(\.hex).contains("#000000"))
}

@Test func aHandfulOfFlatColoursReadsAsFlat() {
    let logo = canvas { ctx in
        let colours: [(Double, Double, Double)] = [(1, 0, 0), (0, 0.6, 0), (0, 0, 1), (1, 0.8, 0), (0.5, 0, 0.5)]
        for (i, c) in colours.enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: i * 25, width: 128, height: 25))
        }
    }
    #expect(ImageStats.measure(logo).verdict == .flat)
}

@Test func continuousToneIsRefusedRatherThanTraced() {
    let photo = canvas { ctx in
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.1, green: 0.2, blue: 0.6, alpha: 1),
            CGColor(srgbRed: 0.9, green: 0.7, blue: 0.2, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 128, y: 128), options: [])
    }
    let stats = ImageStats.measure(photo)
    #expect(stats.verdict == .photographic)
    #expect(!stats.verdict.traceable)
}

@Test func theShareOfEachColourIsRoughlyRight() {
    let half = canvas { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 128))
    }
    let stats = ImageStats.measure(half)
    let black = try! #require(stats.palette.first { $0.hex == "#000000" })
    #expect(black.share > 0.45 && black.share < 0.55)
}

@Test func theSummaryTellsTheModelWhatItWouldOtherwiseGuess() {
    let icon = canvas { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 30, y: 30, width: 60, height: 60))
    }
    let text = ImageStats.measure(icon).summary
    #expect(text.contains("lineArt"))
    #expect(text.contains("#000000"))
    #expect(text.contains("palette"))
}

// MARK: - Scoring a drawing rather than its background

@Test func aBlankPageDoesNotScoreWellAgainstADrawing() {
    // The bug Adam caught from one status line. His icon is about four fifths
    // white, so per-pixel agreement gives an EMPTY page ~80% and a real trace 82%:
    // a metric the loop cannot steer on, because correcting the drawing barely
    // moves it.
    let icon = canvas { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 20, width: 24, height: 88))
        ctx.fill(CGRect(x: 84, y: 20, width: 24, height: 88))
    }
    let blank = canvas { _ in }

    #expect(Compare.score(blank, icon) > 0.7, "per-pixel flatters an empty page")
    #expect(Compare.inkAgreement(blank, icon) < 0.01, "no marks means no agreement")
}

@Test func inkAgreementMovesWhenTheDrawingGetsCloser() {
    let icon = canvas { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 20, width: 24, height: 88))
    }
    let close = canvas { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 24, y: 20, width: 24, height: 88))
    }
    let wrong = canvas { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 84, y: 20, width: 24, height: 88))
    }
    let near = Compare.inkAgreement(close, icon), far = Compare.inkAgreement(wrong, icon)
    #expect(near > far + 0.3, "being nearly right must score far above being elsewhere")
}

@Test func inkWorksTheSameOnWhiteMarksOverBlack() {
    let inverted = canvas { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 30, y: 30, width: 40, height: 60))
    }
    #expect(Compare.inkAgreement(inverted, inverted) > 0.99)
    let empty = canvas { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
    }
    #expect(Compare.inkAgreement(empty, inverted) < 0.01)
}

// MARK: - Telling the model where the marks are

@Test func theInkMapSaysWhereTheMarksActuallyAre() {
    // Ink only in the top-left quarter of the image as it reads.
    let corner = canvas { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 64, width: 64, height: 64))
    }
    let stats = ImageStats.measure(corner)
    #expect(stats.inkGrid.count == 24)
    #expect(stats.inkGrid[0][0] == 9, "the top-left cell is entirely inked")
    #expect(stats.inkGrid[23][23] == 0, "the bottom-right should be empty")
    #expect(stats.inkBounds.minY < 0.05)
    #expect(stats.inkBounds.maxX <= 0.55)
    #expect(stats.summary.contains("where the marks are"))
}

// MARK: - Round caps

@Test func aStrokeCanAskForRoundEnds() {
    var page = Page(name: "P")
    let id = page.add({
        var s = AddSpec()
        s.d = "M 0 0 L 100 0"
        s.stroke = "#000000"; s.strokeWidth = 20; s.strokeCap = "round"
        return s
    }())
    let border = try! #require(id.flatMap { page.layer($0) }).style.borders.first
    #expect(border?.cap == LineCap.round)
    // Round ends with mitred corners is not a thing anyone wants, so one word sets both.
    #expect(border?.join == LineJoin.round)
}

@Test func strokesStayFlatEndedUnlessAsked() {
    var page = Page(name: "P")
    let id = page.add({
        var s = AddSpec(); s.d = "M 0 0 L 100 0"; s.stroke = "#000000"; return s
    }())
    let border = try! #require(id.flatMap { page.layer($0) }).style.borders.first
    #expect(border?.cap == LineCap.butt, "existing artwork must render exactly as it did")
    #expect(border?.join == LineJoin.miter)
}

@Test func roundCapsSurviveSvgAndTheDocumentFormat() throws {
    var page = Page(name: "P")
    _ = page.add({
        var s = AddSpec()
        s.d = "M 10 10 L 90 70"
        s.stroke = "#FF0000"; s.strokeWidth = 8; s.strokeCap = "round"
        return s
    }())
    var doc = Document(); doc.pages = [page]

    let svg = SVGWriter().svg(page: page)
    #expect(svg.contains("stroke-linecap=\"round\""))
    let back = try SVGReader().read(data: Data(svg.utf8))
    let reread = try #require(back.document.pages.first?.layers.first?.style.borders.first)
    #expect(reread.cap == LineCap.round)

    let data = try SkechworksFile.write(document: doc, images: [:])
    let reopened = try SkechworksFile.read(data)
    let saved = try #require(reopened.document.pages.first?.layers.first?.style.borders.first)
    #expect(saved.cap == LineCap.round)
    #expect(saved.join == LineJoin.round)
}

@Test func lineArtIsRecognisedWhateverTheSampleSize() {
    // Counting distinct colours made this flip between line art and flat as the
    // sample size changed, because antialiasing invents a different handful of
    // greys each time. Two-tone is a share of the picture, not a count.
    let icon = canvas { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: 88, height: 88))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 34, y: 34, width: 60, height: 60))
    }
    for samples in [96, 128, 144, 200] {
        #expect(ImageStats.measure(icon, samples: samples).verdict == .lineArt,
                "a black ring on white is line art at any sample size")
    }
}

// MARK: - Showing the difference rather than describing it

@Test func theOverlaySaysWhichMarksAreWrongAndWhichAreMissing() {
    let reference = canvas { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 20, width: 30, height: 88))
    }
    // Drawn in the wrong place entirely: everything is missed, everything is spurious.
    let elsewhere = canvas { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 80, y: 20, width: 30, height: 88))
    }
    let diff = try! #require(Compare.overlay(elsewhere, reference))
    let counts = colourCounts(diff)
    #expect(counts.red > 0, "ink drawn where there is none should show red")
    #expect(counts.grey > 0, "ink not yet drawn should show grey")

    // Drawn correctly: agreement, and neither of the other two.
    let right = try! #require(Compare.overlay(reference, reference))
    let good = colourCounts(right)
    #expect(good.red == 0)
    #expect(good.grey == 0)
    #expect(good.black > 0)
}

private func colourCounts(_ image: CGImage) -> (red: Int, grey: Int, black: Int) {
    let side = image.width
    var buffer = [UInt8](repeating: 0, count: side * side * 4)
    buffer.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: side, height: side,
                            bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    }
    var red = 0, grey = 0, black = 0
    for i in stride(from: 0, to: buffer.count, by: 4) {
        let r = Int(buffer[i]), g = Int(buffer[i + 1]), b = Int(buffer[i + 2])
        if r > 200, g < 80, b < 80 { red += 1 }
        else if abs(r - 190) < 12, abs(g - 190) < 12, abs(b - 190) < 12 { grey += 1 }
        else if r < 40, g < 40, b < 40 { black += 1 }
    }
    return (red, grey, black)
}
