import Foundation

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

        public var errorDescription: String? {
            switch self {
            case .notAFigmaFile: return "That isn't a Figma file."
            case .noDocument: return "The Figma file has no document in it."
            }
        }
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
            // The first chunks are deflated; image blobs later on are not.
            chunks.append(Zip.inflate(piece, expected: size * 8) ?? piece)
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

    private static func u32(_ d: Data, at i: Int) -> UInt32 {
        UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
}
