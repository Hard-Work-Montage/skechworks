import AccompliceCore
import CoreGraphics
import Foundation

// acmplc — the liberator.
//
//   acmplc info     <file.sketch>              what's in it
//   acmplc svg      <file.sketch> -o <dir>     every page as SVG
//   acmplc png      <file.sketch> -o <dir>     every page as PNG
//   acmplc convert  <file.sketch> -o <out>     -> .acmplc.png
//   acmplc verify   <file.acmplc.png>          prove the polyglot holds

let args = CommandLine.arguments
func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("error: \(m)\n".utf8)); exit(1) }

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func usage() -> Never {
    print("""
    acmplc — liberate .sketch files

      acmplc info    <file.sketch>
      acmplc svg     <file.sketch> [-o dir] [--page N]
      acmplc png     <file.sketch> [-o dir] [--page N] [--size 1024]
      acmplc convert <file.sketch> [-o out.acmplc.png] [--cover N]
      acmplc verify  <file.acmplc.png>
      acmplc claim   <file|dir>...        bind files to Accomplice for double-click
      acmplc unclaim <file|dir>...        undo that; files open in Preview again
      acmplc bench   <file.acmplc.png>
    """)
    exit(0)
}

guard args.count >= 3 else { usage() }
let command = args[1]
let input = URL(fileURLWithPath: args[2])

/// Accepts either input format.
///
/// Both are ZIPs containing a `document.json`, so handing an .acmplc.png to the Sketch
/// reader used to "succeed" and yield an empty document — a blank render with no error.
/// Try our own format first and only fall back to Sketch.
func load() -> (Document, [String: Data]) {
    if let (doc, images) = try? AcmplcFile.read(url: input), !doc.pages.isEmpty {
        return (doc, images)
    }
    var reader = SketchReader()
    do {
        let doc = try reader.read(url: input)
        if doc.pages.isEmpty {
            fail("\(input.lastPathComponent): no pages found — is this really a Sketch or Accomplice document?")
        }
        return (doc, reader.images)
    } catch {
        fail("\(input.lastPathComponent): \(error)")
    }
}

func outDir(_ fallback: String) -> URL {
    let u = URL(fileURLWithPath: value("-o") ?? fallback)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func slug(_ s: String, _ i: Int) -> String {
    let base = String(s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" })
        .split(separator: "-").joined(separator: "-")
    return String(format: "%03d-%@", i, base.isEmpty ? "page" : base)
}

func warnFonts() {
    let m = MissingFonts.all
    guard !m.isEmpty else { return }
    FileHandle.standardError.write(Data("\nfont substitutions (text will not match Sketch):\n".utf8))
    for (want, got) in m {
        FileHandle.standardError.write(Data("  \(want) -> \(got)\n".utf8))
    }
}

switch command {

case "info":
    let (doc, images) = load()
    print("\(input.lastPathComponent)")
    print("  imported from : \(doc.sourceApp ?? "unknown")")
    print("  pages         : \(doc.pages.count)")
    print("  embedded imgs : \(images.count)")
    var shapes = 0, texts = 0, bitmaps = 0, groups = 0
    func count(_ ls: [Layer]) {
        for l in ls {
            switch l.kind {
            case .group(let k):        groups += 1; count(k)
            case .shapeGroup(let k, _): shapes += 1; count(k)
            case .path:                shapes += 1
            case .text:                texts += 1
            case .bitmap:              bitmaps += 1
            }
        }
    }
    for p in doc.pages { count(p.layers) }
    print("  shapes/text/bitmaps/groups : \(shapes)/\(texts)/\(bitmaps)/\(groups)")
    print()
    for (i, p) in doc.pages.enumerated() {
        let b = p.contentBounds()
        print(String(format: "  %3d  %-24s %4d layers   %.0fx%.0f",
                     i, (p.name as NSString).utf8String!, p.layers.count, b.width, b.height))
    }

case "svg":
    let (doc, images) = load()
    let dir = outDir(input.deletingPathExtension().lastPathComponent + "-svg")
    let w = SVGWriter(images: images)
    let only = value("--page").flatMap(Int.init)
    var n = 0
    for (i, p) in doc.pages.enumerated() where only == nil || only == i {
        let f = dir.appendingPathComponent(slug(p.name, i) + ".svg")
        try? Data(w.svg(page: p).utf8).write(to: f)
        n += 1
    }
    print("wrote \(n) SVG\(n == 1 ? "" : "s") to \(dir.path)")
    warnFonts()

case "png":
    let (doc, images) = load()
    let dir = outDir(input.deletingPathExtension().lastPathComponent + "-png")
    let size = CGFloat(value("--size").flatMap(Double.init) ?? 1024)
    let r = Renderer(images: images, background: Color(r: 1, g: 1, b: 1, a: 1))
    let only = value("--page").flatMap(Int.init)
    var n = 0
    for (i, p) in doc.pages.enumerated() where only == nil || only == i {
        guard let img = r.render(page: p, maxDimension: size), let d = Renderer.png(img) else { continue }
        try? d.write(to: dir.appendingPathComponent(slug(p.name, i) + ".png"))
        n += 1
    }
    print("wrote \(n) PNG\(n == 1 ? "" : "s") to \(dir.path)")
    warnFonts()

case "convert":
    let (doc, images) = load()
    var opts = AcmplcFile.Options()
    if let c = value("--cover").flatMap(Int.init) { opts.coverPage = c }
    let out = URL(fileURLWithPath: value("-o")
        ?? input.deletingPathExtension().lastPathComponent + ".acmplc.png")
    do {
        let data = try AcmplcFile.write(document: doc, images: images, options: opts)
        try data.write(to: out)
        LaunchBinding.claim(out)
        let kb = Double(data.count) / 1024
        print(String(format: "wrote %@  (%.0f KB, %d pages)", out.lastPathComponent, kb, doc.pages.count))
        // Immediately re-open it both ways. A format that claims to be two things
        // should have to prove it on every single write.
        let back = try Zip.read(try Data(contentsOf: out))
        let svgs = back.keys.filter { $0.hasPrefix("exports/") }.count
        print("  verified: PNG cover + ZIP payload (\(back.count) entries, \(svgs) SVG exports)")
    } catch {
        fail("\(error)")
    }
    warnFonts()

case "resize":
    // Renders a page before and after resizing one layer, so the geometry-scaling
    // behaviour can be checked against real artwork rather than synthetic shapes.
    let (doc, images) = load()
    let idx = value("--page").flatMap(Int.init) ?? 0
    guard doc.pages.indices.contains(idx) else { fail("no page \(idx)") }
    var page = doc.pages[idx]
    guard let target = page.layers.first else { fail("page has no layers") }
    let factor = CGFloat(value("--scale").flatMap(Double.init) ?? 0.5)
    let r = Renderer(images: images, background: Color(r: 1, g: 1, b: 1, a: 1))
    let dir = URL(fileURLWithPath: value("-o") ?? ".")
    if let img = r.render(page: page, maxDimension: 600), let d = Renderer.png(img) {
        try? d.write(to: dir.appendingPathComponent("resize_before.png"))
    }
    page.updateLayer(target.id) {
        $0.resize(to: CGSize(width: $0.frame.width * factor, height: $0.frame.height))
    }
    if let img = r.render(page: page, maxDimension: 600), let d = Renderer.png(img) {
        try? d.write(to: dir.appendingPathComponent("resize_after.png"))
    }
    print("resized '\(target.name)' width x\(factor); wrote resize_before.png / resize_after.png")

case "bench":
    // What the app pays before it can show you anything.
    let t0 = Date()
    guard let src = try? DocumentSource.acmplc(url: input) else { fail("not an .acmplc.png") }
    let indexed = Date().timeIntervalSince(t0)
    let t1 = Date()
    _ = src.page(at: 0)
    let firstPage = Date().timeIntervalSince(t1)
    let t2 = Date()
    for i in 0..<src.pageCount { _ = src.page(at: i) }
    let allPages = Date().timeIntervalSince(t2)
    print(String(format: "index (open)      %6.2fs   %d pages listed", indexed, src.pageCount))
    print(String(format: "first page        %6.2fs", firstPage))
    print(String(format: "remaining %-3d     %6.2fs", src.pageCount - 1, allPages))
    print(String(format: "-- parse to usable window: %.2fs (vs %.2fs eagerly)",
                 indexed + firstPage, indexed + firstPage + allPages))

    // Parsing turned out not to be the cost. Composition is: every shapeGroup runs
    // CGPath boolean ops over its children, and the canvas was redoing that on every
    // single redraw — so scrolling paid the same price as opening.
    let cover = value("--page").flatMap(Int.init) ?? 0
    if let p = src.page(at: cover) {
        let t3 = Date()
        let drawables = Compose.flatten(p.layers)
        let flat = Date().timeIntervalSince(t3)
        print(String(format: "\ncompose page %-2d   %6.2fs   %d drawables", cover, flat, drawables.count))
        print(String(format: "-- that cost was paid on EVERY redraw before caching"))
    }

case "roundtrip":
    // Proves the format is lossless: read the .acmplc.png back into the model, render
    // it, and diff against a render straight from the .sketch original.
    let (original, images) = load()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("acmplc-roundtrip.acmplc.png")
    do {
        try AcmplcFile.write(document: original, images: images).write(to: tmp)
        let (reloaded, reImages) = try AcmplcFile.read(url: tmp)
        print("pages   : \(original.pages.count) written -> \(reloaded.pages.count) read back")
        print("images  : \(images.count) written -> \(reImages.count) read back")

        let a = Renderer(images: images, background: Color(r: 1, g: 1, b: 1, a: 1))
        let b = Renderer(images: reImages, background: Color(r: 1, g: 1, b: 1, a: 1))
        var worst = 0.0, checked = 0
        for (i, p) in original.pages.enumerated() where i < reloaded.pages.count {
            guard let ia = a.render(page: p, maxDimension: 400),
                  let ib = b.render(page: reloaded.pages[i], maxDimension: 400),
                  ia.width == ib.width, ia.height == ib.height,
                  let da = ia.dataProvider?.data as Data?, let db = ib.dataProvider?.data as Data? else { continue }
            var diff = 0
            for k in 0..<min(da.count, db.count) where da[k] != db[k] { diff += 1 }
            let pct = Double(diff) / Double(max(1, min(da.count, db.count))) * 100
            worst = max(worst, pct)
            checked += 1
        }
        print(String(format: "compared: %d pages, worst byte difference %.4f%%", checked, worst))
        print(worst < 0.5 ? "ROUND-TRIP OK" : "ROUND-TRIP LOSSY — investigate")
        try? FileManager.default.removeItem(at: tmp)
        if worst >= 0.5 { exit(2) }
    } catch {
        fail("\(error)")
    }
    warnFonts()

case "claim", "unclaim":
    let removing = command == "unclaim"
    // Re-stamp the per-file Open With binding, e.g. across a library converted
    // before this existed, or after extended attributes were stripped in transit.
    var claimed = 0, skipped = 0
    let targets = args.dropFirst(2).filter { !$0.hasPrefix("-") }
    for path in targets {
        let u = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
        let files: [URL]
        if isDir.boolValue {
            files = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasSuffix(".acmplc.png") || $0.pathExtension == "acmplc" } ?? []
        } else {
            files = [u]
        }
        for f in files {
            let ok = removing ? LaunchBinding.unclaim(f) : LaunchBinding.claim(f)
            if ok { claimed += 1 } else { skipped += 1 }
        }
    }
    let verb = removing ? "unbound" : "bound"
    print("\(verb) \(claimed) file\(claimed == 1 ? "" : "s")\(skipped > 0 ? " (\(skipped) failed)" : "")")
    if claimed > 0 {
        print(removing
            ? "these now open in Preview again, as an ordinary PNG would"
            : "double-clicking these now opens Accomplice; every other PNG still opens in Preview")
    }

case "verify":
    let data: Data
    do { data = try Data(contentsOf: input) } catch { fail("\(error)") }
    let isPNG = data.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    print("\(input.lastPathComponent)  (\(data.count) bytes)")
    print("  PNG signature : \(isPNG ? "ok" : "MISSING")")
    do {
        let z = try Zip.read(data)
        print("  ZIP payload   : ok, \(z.count) entries")
        let exports = z.keys.filter { $0.hasPrefix("exports/") }.sorted()
        print("  SVG exports   : \(exports.count)")
        for e in exports.prefix(5) { print("      \(e)") }
        if exports.count > 5 { print("      … and \(exports.count - 5) more") }
        if !isPNG || z.isEmpty { exit(2) }
    } catch {
        print("  ZIP payload   : MISSING — \(error)")
        print("\n  This file's editable data was stripped, probably by an image optimizer")
        print("  or a re-save from another editor. The picture survives; the document does not.")
        exit(2)
    }

default:
    usage()
}
