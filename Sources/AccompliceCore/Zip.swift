import Compression
import Foundation

// Minimal ZIP reader/writer.
//
// Deliberately hand-rolled and dependency-free. The whole point of this tool is that
// it still works in ten years; inheriting a package graph would undercut that. ZIP's
// central directory format is stable since 1993 and we only need stored + deflate.

public enum ZipError: Error, CustomStringConvertible {
    case notAZip, truncated, unsupported(String), inflateFailed(String)
    public var description: String {
        switch self {
        case .notAZip: return "no ZIP central directory found"
        case .truncated: return "archive truncated"
        case .unsupported(let s): return "unsupported ZIP feature: \(s)"
        case .inflateFailed(let s): return "inflate failed for \(s)"
        }
    }
}

public struct ZipEntry {
    public let name: String
    public let data: Data
}

public enum Zip {

    // MARK: - Reading

    /// Reads a ZIP archive. Tolerates arbitrary bytes *before* the archive, which is
    /// exactly what an `.acmplc.png` polyglot has (a whole PNG sits in front).
    public static func read(_ data: Data) throws -> [String: Data] {
        guard let eocd = findEOCD(data) else { throw ZipError.notAZip }

        let count = Int(u16(data, eocd + 10))
        var cdOffset = Int(u32(data, eocd + 16))
        let cdSize = Int(u32(data, eocd + 12))

        // If bytes were prepended, the stored central-directory offset is stale. The
        // real one sits `cdSize` back from the EOCD; the delta shifts every local header.
        let actualCD = eocd - cdSize
        let prefix = actualCD - cdOffset
        if prefix != 0 { cdOffset = actualCD }

        var out: [String: Data] = [:]
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= data.count, u32(data, p) == 0x0201_4b50 else { throw ZipError.truncated }
            let method = u16(data, p + 10)
            let compSize = Int(u32(data, p + 20))
            let uncompSize = Int(u32(data, p + 24))
            let nameLen = Int(u16(data, p + 28))
            let extraLen = Int(u16(data, p + 30))
            let commentLen = Int(u16(data, p + 32))
            var localOff = Int(u32(data, p + 42)) + prefix

            let name = String(decoding: data[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            guard localOff + 30 <= data.count, u32(data, localOff) == 0x0403_4b50 else { throw ZipError.truncated }
            let lNameLen = Int(u16(data, localOff + 26))
            let lExtraLen = Int(u16(data, localOff + 28))
            localOff += 30 + lNameLen + lExtraLen
            guard localOff + compSize <= data.count else { throw ZipError.truncated }

            if name.hasSuffix("/") { continue }
            let raw = data.subdata(in: localOff..<(localOff + compSize))
            switch method {
            case 0: out[name] = raw
            case 8:
                guard let inflated = inflate(raw, expected: uncompSize) else { throw ZipError.inflateFailed(name) }
                out[name] = inflated
            default: throw ZipError.unsupported("compression method \(method) in \(name)")
            }
        }
        return out
    }

    public static func read(url: URL) throws -> [String: Data] {
        try read(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    // MARK: - Writing

    /// Builds a ZIP. `offsetBase` is added to every recorded offset so the archive
    /// stays self-consistent when appended after a PNG — no `zip -A` fixup needed.
    public static func write(_ entries: [ZipEntry], offsetBase: Int = 0) -> Data {
        var body = Data(), central = Data()
        var n = 0
        for e in entries {
            let nameBytes = Array(e.name.utf8)
            let crc = crc32(e.data)
            var payload = e.data
            var method: UInt16 = 0
            if e.data.count > 64, let z = deflate(e.data), z.count < e.data.count {
                payload = z; method = 8
            }
            let localOffset = offsetBase + body.count

            var lh = Data()
            lh.append(u32le(0x0403_4b50)); lh.append(u16le(20)); lh.append(u16le(0))
            lh.append(u16le(method)); lh.append(u16le(0)); lh.append(u16le(0))
            lh.append(u32le(crc)); lh.append(u32le(UInt32(payload.count))); lh.append(u32le(UInt32(e.data.count)))
            lh.append(u16le(UInt16(nameBytes.count))); lh.append(u16le(0))
            lh.append(contentsOf: nameBytes)
            body.append(lh); body.append(payload)

            var ch = Data()
            ch.append(u32le(0x0201_4b50)); ch.append(u16le(20)); ch.append(u16le(20)); ch.append(u16le(0))
            ch.append(u16le(method)); ch.append(u16le(0)); ch.append(u16le(0))
            ch.append(u32le(crc)); ch.append(u32le(UInt32(payload.count))); ch.append(u32le(UInt32(e.data.count)))
            ch.append(u16le(UInt16(nameBytes.count))); ch.append(u16le(0)); ch.append(u16le(0))
            ch.append(u16le(0)); ch.append(u16le(0)); ch.append(u32le(0))
            ch.append(u32le(UInt32(localOffset)))
            ch.append(contentsOf: nameBytes)
            central.append(ch)
            n += 1
        }
        var out = body
        let cdOffset = offsetBase + body.count
        out.append(central)
        var eocd = Data()
        eocd.append(u32le(0x0605_4b50)); eocd.append(u16le(0)); eocd.append(u16le(0))
        eocd.append(u16le(UInt16(n))); eocd.append(u16le(UInt16(n)))
        eocd.append(u32le(UInt32(central.count))); eocd.append(u32le(UInt32(cdOffset)))
        eocd.append(u16le(0))
        out.append(eocd)
        return out
    }

    // MARK: - Plumbing

    private static func findEOCD(_ d: Data) -> Int? {
        guard d.count >= 22 else { return nil }
        let lowest = max(0, d.count - 66_000)
        var i = d.count - 22
        while i >= lowest {
            if u32(d, i) == 0x0605_4b50 { return i }
            i -= 1
        }
        return nil
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 {
        guard o + 2 <= d.count else { return 0 }
        return UInt16(d[d.startIndex + o]) | (UInt16(d[d.startIndex + o + 1]) << 8)
    }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= d.count else { return 0 }
        var v: UInt32 = 0
        for k in (0..<4).reversed() { v = (v << 8) | UInt32(d[d.startIndex + o + k]) }
        return v
    }
    private static func u16le(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    private static func u32le(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }

    /// Raw DEFLATE, no zlib wrapper. Shared with the Figma reader, whose chunks
    /// are deflated the same way a zip entry is.
    public static func inflate(_ src: Data, expected: Int) -> Data? {
        if src.isEmpty { return Data() }
        // Generous headroom: `expected` can be 0 when a writer used a data descriptor.
        var cap = max(expected, src.count * 8) + 8192
        for _ in 0..<4 {
            var dst = Data(count: cap)
            let n = dst.withUnsafeMutableBytes { d -> Int in
                src.withUnsafeBytes { s -> Int in
                    compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, cap,
                                              s.bindMemory(to: UInt8.self).baseAddress!, src.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 && (n < cap || expected == n) { dst.count = n; return dst }
            if n > 0 && n == cap && expected > 0 && n >= expected { dst.count = n; return dst }
            cap *= 4
        }
        return nil
    }

    private static func deflate(_ src: Data) -> Data? {
        let cap = src.count + 4096
        var dst = Data(count: cap)
        let n = dst.withUnsafeMutableBytes { d -> Int in
            src.withUnsafeBytes { s -> Int in
                compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        dst.count = n
        return dst
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    public static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
