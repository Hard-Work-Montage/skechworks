import SkechworksCore
import CoreGraphics
import Foundation

// sw — the liberator.
//
//   sw info     <file.sketch>              what's in it
//   sw svg      <file.sketch> -o <dir>     every page as SVG
//   sw png      <file.sketch> -o <dir>     every page as PNG
//   sw convert  <file.sketch> -o <out>     -> .sw.png
//   sw verify   <file.sw.png>          prove the polyglot holds

let args = CommandLine.arguments
func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("error: \(m)\n".utf8)); exit(1) }

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func usage() -> Never {
    print("""
    sw — liberate .sketch files

      sw info    <file.sketch>
      sw svg     <file.sketch> [-o dir] [--page N]
      sw png     <file.sketch> [-o dir] [--page N] [--size 1024]
      sw convert <file.sketch> [-o out.sw.png] [--cover N]
      sw verify  <file.sw.png>
      sw claim   <file|dir>...        bind files to Skechworks for double-click
      sw unclaim <file|dir>...        undo that; files open in Preview again
      sw bench   <file.sw.png>
    """)
    exit(0)
}

guard args.count >= 3 else { usage() }
let command = args[1]
let input = URL(fileURLWithPath: args[2])

/// Accepts either input format.
///
/// Both are ZIPs containing a `document.json`, so handing an .sw.png to the Sketch
/// reader used to "succeed" and yield an empty document — a blank render with no error.
/// Try our own format first and only fall back to Sketch.
func load() -> (Document, [String: Data]) {
    if input.pathExtension.lowercased() == "svg" {
        do {
            let r = try SVGReader().read(url: input)
            for w in r.warnings { FileHandle.standardError.write(Data("note: \(w)\n".utf8)) }
            return (r.document, r.images)
        } catch {
            fail("\(input.lastPathComponent): \(error)")
        }
    }
    if let (doc, images) = try? SkechworksFile.read(url: input), !doc.pages.isEmpty {
        return (doc, images)
    }
    var reader = SketchReader()
    do {
        let doc = try reader.read(url: input)
        if doc.pages.isEmpty {
            fail("\(input.lastPathComponent): no pages found — is this really a Sketch or Skechworks document?")
        }
        return (doc, reader.images)
    } catch {
        fail("\(input.lastPathComponent): \(error)")
    }
}

func flag(_ name: String) -> Bool { args.contains(name) }

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
    var opts = SkechworksFile.Options()
    if let c = value("--cover").flatMap(Int.init) { opts.coverPage = c }
    let out = URL(fileURLWithPath: value("-o")
        ?? input.deletingPathExtension().lastPathComponent + ".sw.png")
    do {
        let data = try SkechworksFile.write(document: doc, images: images, options: opts)
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

case "vpcheck":
    // Round-trips every path in a document through VectorPath and reports any drift.
    // The pen tool edits points and writes a CGPath back, so any loss here would
    // corrupt geometry on every single edit.
    let (doc, _) = load()
    var total = 0, mismatched = 0, quadOnly = 0, geometric = 0
    let w = SVGWriter()
    func walk(_ ls: [Layer]) {
        for l in ls {
            switch l.kind {
            case .path(let p, _):
                total += 1
                let back = VectorPath(cgPath: p).cgPath()
                let a = w.pathData(p), b = w.pathData(back)
                if a != b {
                    mismatched += 1
                    // A quadratic converts to an exactly equivalent cubic, so the
                    // string differs while the shape doesn't. Anything else is a
                    // genuine geometry change and must be reported as such.
                    if a.contains("Q") { quadOnly += 1 }
                    else {
                        let d = max(abs(p.boundingBox.minX - back.boundingBox.minX),
                                    abs(p.boundingBox.maxY - back.boundingBox.maxY))
                        if d > 0.01 { geometric += 1 }
                    }
                }
            case .group(let k), .shapeGroup(let k, _): walk(k)
            default: break
            }
        }
    }
    for p in doc.pages { walk(p.layers) }
    print("paths \(total) · identical \(total - mismatched) · quad→cubic \(quadOnly) · GEOMETRY CHANGED \(geometric)")
    if geometric > 0 { exit(2) }

case "artboards":
    // Exercises the same isolate() path the app's Export Artboards uses.
    let (doc, images) = load()
    let dir = outDir("artboards")
    var n = 0
    for page in doc.pages {
        for board in page.artboards {
            guard let iso = page.isolate(board.id) else { continue }
            let base = board.name.replacingOccurrences(of: " ", with: "-")
            // --png renders instead of writing SVG: the same artboard, rasterised
            // at --size, which is what a website wants.
            if flag("--png") {
                let px = value("--size").flatMap { CGFloat(Double($0) ?? 0) } ?? 1024
                if let img = Renderer(images: images, honorsExportFlags: true)
                    .render(page: iso.page, maxDimension: px, bounds: iso.bounds),
                   let d = Renderer.png(img) {
                    try? d.write(to: dir.appendingPathComponent("\(base).png"))
                }
            } else {
                let svg = SVGWriter(images: images).svg(page: iso.page, bounds: iso.bounds)
                try? Data(svg.utf8).write(to: dir.appendingPathComponent("\(base).svg"))
            }
            print(String(format: "  %-16s %.0fx%.0f", (board.name as NSString).utf8String!,
                         iso.bounds.width, iso.bounds.height))
            n += 1
        }
    }
    print("exported \(n) artboards")

case "bench":
    // A big SVG: the same costs, minus the archive.
    if input.pathExtension.lowercased() == "svg" {
        let t0 = Date()
        guard let r = try? SVGReader().read(url: input) else { fail("can't read that SVG") }
        let read = Date().timeIntervalSince(t0)
        let page = r.document.pages[0]
        print(String(format: "read              %6.2fs   %d top-level layers", read, page.layers.count))

        let t1 = Date()
        let drawables = Compose.flatten(page.layers)
        let flat = Date().timeIntervalSince(t1)
        print(String(format: "compose           %6.2fs   %d drawables", flat, drawables.count))

        let t2 = Date()
        var union = CGRect.null
        for d in drawables { if let p = d.path { union = union.union(p.boundingBoxOfPath) } }
        let boxes = Date().timeIntervalSince(t2)
        print(String(format: "bounding boxes    %6.2fs   (paid per redraw wherever they aren't cached)", boxes))

        let t3 = Date()
        _ = Renderer(images: r.images).render(page: page, maxDimension: 1024)
        let render = Date().timeIntervalSince(t3)
        print(String(format: "render @1024      %6.2fs   (~one full canvas redraw)", render))

        let t4 = Date()
        _ = Compose.flatten(page.layers, adjusting: [ page.layers[0].id ], live: .identity)
        let tick = Date().timeIntervalSince(t4)
        print(String(format: "drag-tick reflatten %4.2fs (paid per mouse move while dragging)", tick))
        exit(0)
    }

    // What the app pays before it can show you anything.
    let t0 = Date()
    guard let src = try? DocumentSource.sw(url: input) else { fail("not an .sw.png") }
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
    // Proves the format is lossless: read the .sw.png back into the model, render
    // it, and diff against a render straight from the .sketch original.
    let (original, images) = load()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sw-roundtrip.sw.png")
    do {
        try SkechworksFile.write(document: original, images: images).write(to: tmp)
        let (reloaded, reImages) = try SkechworksFile.read(url: tmp)
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

case "ask":
    // The end-to-end harness: real document, real model, real decoder, real executor.
    //
    // Every model-facing bug so far — the strict `hex` key, the unscoped delete —
    // survived unit tests and died the moment a real reply came back. Assumptions
    // about what a model emits are worth nothing; this makes checking cheap.
    let (doc0, askImages) = load()
    var doc = doc0
    let pageIndex = value("--page").flatMap(Int.init) ?? 0
    guard pageIndex < doc.pages.count else { fail("no page \(pageIndex)") }
    // args = [sw, ask, <file>, <request>, ...] — skip the file, not just the verb.
    guard let request = args.dropFirst(3).first(where: { !$0.hasPrefix("-") }) else {
        fail("usage: sw ask <file> \"request\"")
    }
    let host = value("--host") ?? "http://127.0.0.1:11434"
    let model = value("--model") ?? "qwen3-coder:30b"

    let described = doc.pages[pageIndex].describe()
    let body: [String: Any] = [
        "model": model, "stream": false, "format": "json",
        "options": ["temperature": 0.1],
        "messages": [
            ["role": "system", "content": ModelPrompt.system],
            ["role": "user", "content": ModelPrompt.user(document: described, request: request)],
        ],
    ]
    var req = URLRequest(url: URL(string: host + "/api/chat")!)
    req.httpMethod = "POST"
    req.timeoutInterval = 300
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try! JSONSerialization.data(withJSONObject: body)

    let sem = DispatchSemaphore(value: 0)
    var reply = ""
    var transportError: String?
    URLSession.shared.dataTask(with: req) { data, _, err in
        defer { sem.signal() }
        if let err { transportError = err.localizedDescription; return }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = json["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            transportError = "unreadable reply from \(host)"
            return
        }
        reply = content
    }.resume()
    sem.wait()
    if let transportError { fail(transportError) }

    print("--- model said ---")
    print(reply.trimmingCharacters(in: .whitespacesAndNewlines))
    let turn = ModelTurn.decode(Data(reply.utf8))
    print("\n--- decoded ---")
    print("say      : \(turn.say)")
    print("commands : \(turn.commands.count)")
    for p in turn.problems { print("PROBLEM  : \(p)") }

    let before = doc.pages[pageIndex].contentSignature
    var page = doc.pages[pageIndex]
    let outcome = page.run(turn.commands, selection: [])
    doc.pages[pageIndex] = page
    let changed = page.contentSignature != before
    print("\n--- applied ---")
    print(outcome.report)
    print(changed ? "DOCUMENT CHANGED" : "DOCUMENT UNCHANGED")
    // A model claiming work it didn't do is the failure this command exists to catch.
    if !turn.say.isEmpty && !turn.commands.isEmpty && !changed { exit(3) }
    if let out = value("--save") {
        // Lets the result be looked at, not just reported on.
        // Carry the images through: writing with an empty map silently strips every
        // embedded bitmap, which would make this harness destructive.
        let data = try! SkechworksFile.write(document: doc, images: askImages)
        try! data.write(to: URL(fileURLWithPath: out))
        print("saved \(out)")
    }
    if !turn.problems.isEmpty { exit(4) }

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
                .filter { $0.lastPathComponent.hasSuffix(".sw.png") || $0.pathExtension == "sw" } ?? []
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
            : "double-clicking these now opens Skechworks; every other PNG still opens in Preview")
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
