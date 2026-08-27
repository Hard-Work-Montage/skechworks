import Foundation

/// zstd's two entry points, named rather than imported.
///
/// The decompressor is compiled into this framework by Xcode and built as a
/// separate C module by SwiftPM. Importing it works in one and not the other,
/// and making a framework re-export someone else's Clang module to call two
/// functions is a lot of build system for very little. Naming the symbols links
/// the same way under both, and a signature that didn't match upstream would
/// fail at link time rather than quietly.
@_silgen_name("ZSTD_decompress")
private func zstd_decompress(_ dst: UnsafeMutableRawPointer?, _ dstCapacity: Int,
                             _ src: UnsafeRawPointer?, _ srcSize: Int) -> UInt

@_silgen_name("ZSTD_getFrameContentSize")
private func zstd_contentSize(_ src: UnsafeRawPointer?, _ srcSize: Int) -> UInt64

/// Unpacking a Figma document far enough to read it.
///
/// A .fig is a header, then a run of deflated chunks. The FIRST chunk is the
/// Kiwi schema the rest was written with and the second is the document, so the
/// file explains itself and nothing here has to know Figma's model.
///
/// Some .fig files are zips instead, with the real thing inside as canvas.fig,
/// which is how one carrying bitmaps arrives.
public enum FigFile {

    public static let magic = "fig-kiwi"

    public struct Unpacked {
        public var schema: Kiwi.Schema
        public var document: Kiwi.Value
        /// Everything after the document: image blobs, mostly.
        public var extras: [Data]
    }

    public enum Failure: LocalizedError {
        case notAFigmaFile
        case noDocument
        case needsZstd

        public var errorDescription: String? {
            switch self {
            case .notAFigmaFile: return "That isn't a Figma file."
            case .noDocument: return "The Figma file has no document in it."
            case .needsZstd:
                return "This Figma file is compressed in a way that couldn't be read."
            }
        }
    }

    /// Zstandard's frame magic. Figma deflates the schema and zstd-compresses the
    /// document, and macOS has no zstd — Compression offers zlib, lzma, lz4,
    /// brotli and lzfse and nothing else. Recognised here so the file says what's
    /// wrong instead of decoding rubbish into an empty document.
    private static func isZstd(_ d: Data) -> Bool {
        d.count >= 4 && d[d.startIndex] == 0x28 && d[d.startIndex + 1] == 0xB5
            && d[d.startIndex + 2] == 0x2F && d[d.startIndex + 3] == 0xFD
    }

    public static func unpack(url: URL) throws -> Unpacked {
        try unpack(data: try Data(contentsOf: url))
    }

    public static func unpack(data raw: Data) throws -> Unpacked {
        let data = try payload(raw)
        guard data.count > 12, data.prefix(8) == Data(magic.utf8) else { throw Failure.notAFigmaFile }

        var chunks: [Data] = []
        var i = data.startIndex + 12   // magic, then a version word
        while i + 4 <= data.endIndex {
            let size = Int(u32(data, at: i))
            i += 4
            guard size >= 0, i + size <= data.endIndex else { break }
            let piece = data.subdata(in: i..<(i + size))
            i += size
            // Figma deflates the schema and zstd-compresses the document, so
            // both live in the same run of chunks and each says which it is.
            if isZstd(piece) {
                guard let out = unzstd(piece) else { throw Failure.needsZstd }
                chunks.append(out)
            } else {
                chunks.append(Zip.inflate(piece, expected: size * 8) ?? piece)
            }
        }

        guard chunks.count >= 2 else { throw Failure.noDocument }
        let schema = try Kiwi.schema(from: chunks[0])
        // Figma's root has been called Message for a long time, but the schema
        // names every definition, so the right one can be found rather than
        // assumed — that's the whole reason this survives their versions.
        let rootName = schema.definitions.first(where: { $0.name == "Message" })?.name
            ?? schema.definitions.first(where: { $0.kind == 2 })?.name
        guard let rootName else { throw Failure.noDocument }
        let document = try Kiwi.decode(chunks[1], schema: schema, as: rootName)
        return Unpacked(schema: schema, document: document, extras: Array(chunks.dropFirst(2)))
    }

    /// A .fig that's really a zip carries the document inside it.
    private static func payload(_ raw: Data) throws -> Data {
        guard raw.prefix(2) == Data([0x50, 0x4B]) else { return raw }
        let entries = (try? Zip.read(raw)) ?? [:]
        if let inner = entries.first(where: { $0.key.lowercased().hasSuffix(".fig") })?.value {
            return inner
        }
        if let canvas = entries["canvas.fig"] { return canvas }
        throw Failure.notAFigmaFile
    }

    /// Decompresses a zstd frame.
    ///
    /// The frame usually declares its own size, which makes this one allocation
    /// and one call. When it doesn't — a stream written without knowing the
    /// total — the size comes back as unknown and the buffer is grown instead
    /// of trusting a number that isn't there.
    static func unzstd(_ src: Data) -> Data? {
        let declared = src.withUnsafeBytes { zstd_contentSize($0.baseAddress, src.count) }
        let unknown = UInt64.max                    // ZSTD_CONTENTSIZE_UNKNOWN
        let bad = UInt64.max - 1                    // ZSTD_CONTENTSIZE_ERROR
        if declared == bad { return nil }

        var capacity = declared == unknown ? max(src.count * 8, 1 << 16) : Int(declared)
        for _ in 0..<6 {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { d -> Int in
                src.withUnsafeBytes { s -> Int in
                    // zstd reports errors as enormous unsigned values, so this
                    // is compared as a size, never converted to a signed count
                    // and hoped about.
                    let n = zstd_decompress(d.baseAddress, capacity, s.baseAddress, src.count)
                    return n <= UInt(capacity) ? Int(n) : -1
                }
            }
            if written >= 0 {
                out.count = written
                return out
            }
            guard declared == unknown else { return nil }
            capacity *= 4
        }
        return nil
    }

    private static func u32(_ d: Data, at i: Int) -> UInt32 {
        UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
}
