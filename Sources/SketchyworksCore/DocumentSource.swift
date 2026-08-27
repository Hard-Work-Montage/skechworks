import CoreGraphics
import Foundation

// A document you can browse before you've paid to parse it.
//
// Eagerly reading an .sw.png meant running every shape in the file through the
// path parser at open time — 24,665 of them in the moon-phases coin, for ~15s before
// the window showed anything. But `document.json` already carries each page's name and
// layer count, which is everything the sidebar needs. So the index is free and the
// geometry is parsed per page, on demand, once.

/// `@unchecked Sendable`: the page cache is the only mutable state and every access
/// goes through `lock`.
/// Which files are Sketchyworks documents rather than content to place.
///
/// Lives here so it's testable and there's exactly one answer: routing a dropped file
/// through the open path when it wasn't a document used to destroy the open one.
public enum DocumentKind {
    public static func isDocument(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        return SketchyworksFile.isOwnDocumentName(n)
            || n.hasSuffix(".sketch") || n.hasSuffix(".svg")
    }
}

public final class DocumentSource: @unchecked Sendable {

    public struct PageRef: Sendable {
        public let name: String
        public let layerCount: Int
    }

    public let sourceApp: String?
    public let images: [String: Data]
    public private(set) var pages: [PageRef]
    /// Where each current page came from in the file, or nil if it was made here.
    ///
    /// The parser resolves by position in the ORIGINAL document. Insert a page at the
    /// front and every later position shifts, so resolving by current index would hand
    /// back somebody else's artwork. This keeps the two apart.
    private var origin: [Int?] = []
    public let coverPage: Int

    private let resolve: @Sendable (Int) -> Page?
    fileprivate var cache: [Int: Page] = [:]
    private let lock = NSLock()

    public var pageCount: Int { pages.count }

    /// Parses page `i` on first request and remembers it.
    public func page(at i: Int) -> Page? {
        guard pages.indices.contains(i) else { return nil }
        lock.lock()
        if let hit = cache[i] { lock.unlock(); return hit }
        let from = origin.indices.contains(i) ? origin[i] : i
        lock.unlock()
        // A page added in the editor has no position in the file; it lives in the
        // cache or nowhere.
        guard let from else { return nil }

        let parsed = resolve(from)
        lock.lock()
        cache[i] = parsed
        lock.unlock()
        return parsed
    }

    // MARK: - Changing the page list
    //
    // Everything here rebuilds the cache and the origin map together. They're indexed
    // by position, so an insert or a remove has to move both or a page ends up showing
    // another page's artwork — the failure would look like corruption rather than a
    // reordering bug.

    /// Adds a page and returns where it landed.
    @discardableResult
    public func insert(_ page: Page, at index: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let at = max(0, min(index, pages.count))
        pages.insert(PageRef(name: page.name, layerCount: page.layers.count), at: at)
        origin.insert(nil, at: at)              // made here, not in the file
        cache = Self.shifted(cache, insertingAt: at)
        cache[at] = page
        return at
    }

    /// Removes a page, handing back what was there so it can be put back.
    @discardableResult
    public func remove(at index: Int) -> Page? {
        lock.lock()
        guard pages.indices.contains(index), pages.count > 1 else { lock.unlock(); return nil }
        let from = origin[index]
        let held = cache[index]
        pages.remove(at: index)
        origin.remove(at: index)
        cache = Self.shifted(cache, removingAt: index)
        lock.unlock()
        return held ?? from.flatMap { resolve($0) }
    }

    /// Reorders a page. `to` is the position it should end up at.
    @discardableResult
    public func move(from: Int, to: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pages.indices.contains(from) else { return false }
        let target = max(0, min(to, pages.count - 1))
        guard target != from else { return false }

        let ref = pages.remove(at: from)
        let source = origin.remove(at: from)
        let held = cache[from]
        cache = Self.shifted(cache, removingAt: from)
        pages.insert(ref, at: target)
        origin.insert(source, at: target)
        cache = Self.shifted(cache, insertingAt: target)
        cache[target] = held
        return true
    }

    public func rename(at index: Int, to name: String) {
        lock.lock(); defer { lock.unlock() }
        guard pages.indices.contains(index) else { return }
        pages[index] = PageRef(name: name, layerCount: pages[index].layerCount)
        if var p = cache[index] { p.name = name; cache[index] = p }
    }

    private static func shifted(_ cache: [Int: Page], insertingAt at: Int) -> [Int: Page] {
        var out: [Int: Page] = [:]
        for (k, v) in cache { out[k >= at ? k + 1 : k] = v }
        return out
    }

    private static func shifted(_ cache: [Int: Page], removingAt at: Int) -> [Int: Page] {
        var out: [Int: Page] = [:]
        for (k, v) in cache where k != at { out[k > at ? k - 1 : k] = v }
        return out
    }

    public func isLoaded(_ i: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cache[i] != nil
    }

    /// Writes an edited page back over the cache, so lazy loading and editing coexist:
    /// pages you've touched come from here, pages you haven't are still parsed on demand.
    public func replacePage(_ page: Page, at i: Int) {
        guard pages.indices.contains(i) else { return }
        lock.lock()
        cache[i] = page
        lock.unlock()
    }

    /// A copy carrying one more asset. Placing an image has to add its bytes to the
    /// document, and images are otherwise fixed at load time.
    public func adding(image data: Data, key: String) -> DocumentSource {
        var imgs = images
        imgs[key] = data
        let copy = DocumentSource(sourceApp: sourceApp, images: imgs, pages: pages,
                                  coverPage: coverPage, resolve: resolve)
        lock.lock()
        let snapshot = cache
        lock.unlock()
        copy.lock.lock()
        copy.cache = snapshot
        copy.lock.unlock()
        return copy
    }

    /// Forces everything. Only for operations that genuinely need the whole document,
    /// like Export All — never on open.
    public func fullDocument() -> Document {
        var d = Document()
        d.sourceApp = sourceApp
        d.pages = (0..<pages.count).compactMap { page(at: $0) }
        return d
    }

    // MARK: - Sources

    /// Lazy over an .sw.png. Only `document.json` is parsed up front.
    public static func sw(url: URL) throws -> DocumentSource {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let z: [String: Data]
        do { z = try Zip.read(data) } catch { throw SketchyworksFile.ReadError.stripped }
        guard let docData = z["document.json"],
              let dj = try? JSONSerialization.jsonObject(with: docData) as? [String: Any],
              let entries = dj["pages"] as? [[String: Any]] else {
            throw SketchyworksFile.ReadError.stripped
        }
        // Sketch files are zips with a document.json and a "pages" array too — the
        // guard above can't tell them apart, and treating one as ours produced a
        // hollow "1 page, 0 layers" document with the Sketch reader never consulted.
        if dj["_class"] != nil || entries.contains(where: { !($0["file"] is String) }) {
            throw SketchyworksFile.ReadError.notSketchyworks
        }

        let refs = entries.map {
            PageRef(name: $0["name"] as? String ?? "Page", layerCount: $0["layers"] as? Int ?? 0)
        }
        let files = entries.map { $0["file"] as? String ?? "" }

        var images: [String: Data] = [:]
        for (k, v) in z where k.hasPrefix("assets/") {
            images[String(k.dropFirst("assets/".count))] = v
        }

        return DocumentSource(sourceApp: dj["importedFrom"] as? String,
                              images: images, pages: refs,
                              coverPage: dj["coverPage"] as? Int ?? 0) { i in
            guard let d = z[files[i]] else { return nil }
            return SketchyworksFile.parsePage(d)
        }
    }

    /// Wraps an already-parsed document, so callers have one type to handle.
    public static func eager(_ doc: Document, images: [String: Data]) -> DocumentSource {
        let refs = doc.pages.map { PageRef(name: $0.name, layerCount: $0.layers.count) }
        let src = DocumentSource(sourceApp: doc.sourceApp, images: images, pages: refs,
                                 coverPage: 0) { i in
            doc.pages.indices.contains(i) ? doc.pages[i] : nil
        }
        // Prime the cache. Nothing here needs parsing — the pages are already in
        // memory — but an empty cache reports "not loaded", which sent a brand new
        // document off through a background task to fetch what the caller just handed
        // over, leaving `page` briefly nil for no reason.
        for i in doc.pages.indices { src.cache[i] = doc.pages[i] }
        return src
    }

    private init(sourceApp: String?, images: [String: Data], pages: [PageRef],
                 coverPage: Int, resolve: @escaping @Sendable (Int) -> Page?) {
        self.origin = pages.indices.map { $0 }
        self.sourceApp = sourceApp
        self.images = images
        self.pages = pages
        self.coverPage = coverPage
        self.resolve = resolve
    }
}
