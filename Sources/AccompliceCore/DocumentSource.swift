import CoreGraphics
import Foundation

// A document you can browse before you've paid to parse it.
//
// Eagerly reading an .acmplc.png meant running every shape in the file through the
// path parser at open time — 24,665 of them in the moon-phases coin, for ~15s before
// the window showed anything. But `document.json` already carries each page's name and
// layer count, which is everything the sidebar needs. So the index is free and the
// geometry is parsed per page, on demand, once.

/// `@unchecked Sendable`: the page cache is the only mutable state and every access
/// goes through `lock`.
/// Which files are Accomplice documents rather than content to place.
///
/// Lives here so it's testable and there's exactly one answer: routing a dropped file
/// through the open path when it wasn't a document used to destroy the open one.
public enum DocumentKind {
    public static func isDocument(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        return n.hasSuffix(".acmplc.png") || n.hasSuffix(".acmplc")
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
    public let pages: [PageRef]
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
        lock.unlock()

        let parsed = resolve(i)
        lock.lock()
        cache[i] = parsed
        lock.unlock()
        return parsed
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

    /// Lazy over an .acmplc.png. Only `document.json` is parsed up front.
    public static func acmplc(url: URL) throws -> DocumentSource {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let z: [String: Data]
        do { z = try Zip.read(data) } catch { throw AcmplcFile.ReadError.stripped }
        guard let docData = z["document.json"],
              let dj = try? JSONSerialization.jsonObject(with: docData) as? [String: Any],
              let entries = dj["pages"] as? [[String: Any]] else {
            throw AcmplcFile.ReadError.stripped
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
            return AcmplcFile.parsePage(d)
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
        self.sourceApp = sourceApp
        self.images = images
        self.pages = pages
        self.coverPage = coverPage
        self.resolve = resolve
    }
}
