import Foundation

/// Reading Kiwi, the binary format Figma writes its documents in.
///
/// The reason a .fig can be opened at all: a Kiwi file carries its own SCHEMA
/// alongside its data. Field names, types and ids all arrive in the file, so
/// this reads a document without knowing anything about Figma's model — and
/// keeps reading one after they add fields, rename things, or renumber them.
/// Nothing here is a guess about their internals that goes stale.
///
/// Spec: github.com/evanw/kiwi. Values come back as a plain tree so the mapping
/// to our own model is ordinary Swift rather than more parsing.
public enum Kiwi {

    public indirect enum Value {
        case bool(Bool)
        case byte(UInt8)
        case int(Int32)
        case uint(UInt32)
        case int64(Int64)
        case uint64(UInt64)
        case double(Double)
        case string(String)
        case object([String: Value])
        case array([Value])

        public var number: Double? {
            switch self {
            case .double(let d): return d
            case .int(let i): return Double(i)
            case .uint(let u): return Double(u)
            case .int64(let i): return Double(i)
            case .uint64(let u): return Double(u)
            case .byte(let b): return Double(b)
            case .bool(let b): return b ? 1 : 0
            default: return nil
            }
        }
        public var text: String? { if case .string(let s) = self { return s }; return nil }
        public var fields: [String: Value]? { if case .object(let o) = self { return o }; return nil }
        public var items: [Value]? { if case .array(let a) = self { return a }; return nil }
        public subscript(_ key: String) -> Value? { fields?[key] }
    }

    public enum Failure: LocalizedError {
        case truncated
        case badSchema(String)

        public var errorDescription: String? {
            switch self {
            case .truncated: return "The file ends in the middle of something."
            case .badSchema(let s): return "The file's own schema couldn't be read: \(s)"
            }
        }
    }

    // MARK: - Schema

    public struct Schema {
        public struct Field {
            public var name: String
            public var type: Int32
            public var isArray: Bool
            public var value: UInt32
        }
        public struct Definition {
            public var name: String
            /// 0 enum, 1 struct, 2 message.
            public var kind: UInt8
            public var fields: [Field]
        }
        public var definitions: [Definition]

        public func index(of name: String) -> Int? {
            definitions.firstIndex { $0.name == name }
        }
    }

    public static func schema(from data: Data) throws -> Schema {
        var r = Reader(data)
        let count = try r.varuint()
        var defs: [Schema.Definition] = []
        defs.reserveCapacity(Int(count))
        for _ in 0..<count {
            let name = try r.string()
            let kind = try r.byte()
            guard kind <= 2 else { throw Failure.badSchema("unknown kind \(kind) for \(name)") }
            let fieldCount = try r.varuint()
            var fields: [Schema.Field] = []
            fields.reserveCapacity(Int(fieldCount))
            for _ in 0..<fieldCount {
                let fname = try r.string()
                let type = try r.varint()
                let isArray = try r.byte() != 0
                let value = try r.varuint()
                fields.append(Schema.Field(name: fname, type: type, isArray: isArray, value: value))
            }
            defs.append(Schema.Definition(name: name, kind: kind, fields: fields))
        }
        return Schema(definitions: defs)
    }

    // MARK: - Message

    /// Decodes `data` as the named definition from `schema`.
    public static func decode(_ data: Data, schema: Schema, as root: String) throws -> Value {
        guard let index = schema.index(of: root) else {
            throw Failure.badSchema("no definition called \(root)")
        }
        var r = Reader(data)
        return try value(&r, schema: schema, type: Int32(index))
    }

    private static func value(_ r: inout Reader, schema: Schema, type: Int32) throws -> Value {
        switch type {
        case -1: return .bool(try r.byte() != 0)
        case -2: return .byte(try r.byte())
        case -3: return .int(Int32(truncatingIfNeeded: try r.varint()))
        case -4: return .uint(UInt32(truncatingIfNeeded: try r.varuint()))
        case -5: return .double(Double(try r.float()))
        case -6: return .string(try r.string())
        case -7: return .int64(try r.varint64())
        case -8: return .uint64(try r.varuint64())
        default:
            let i = Int(type)
            guard i >= 0, i < schema.definitions.count else { throw Failure.badSchema("type \(type)") }
            return try compound(&r, schema: schema, definition: schema.definitions[i])
        }
    }

    private static func compound(_ r: inout Reader, schema: Schema,
                                 definition d: Schema.Definition) throws -> Value {
        switch d.kind {
        case 0:
            // An enum is a number on the wire; the NAME is what's worth having.
            let raw = UInt32(truncatingIfNeeded: try r.varuint())
            if let f = d.fields.first(where: { $0.value == raw }) { return .string(f.name) }
            return .uint(raw)

        case 1:
            // A struct writes every field, in order, with no ids and no terminator.
            var out: [String: Value] = [:]
            for f in d.fields {
                out[f.name] = try field(&r, schema: schema, field: f)
            }
            return .object(out)

        default:
            // A message writes (id, value) pairs and stops at id 0. An id this
            // schema doesn't describe can't be skipped — the wire says nothing
            // about a value's length — so that ends the object rather than
            // reading rubbish as if it were data.
            var out: [String: Value] = [:]
            while true {
                let id = try r.varuint()
                if id == 0 { break }
                guard let f = d.fields.first(where: { $0.value == id }) else { break }
                out[f.name] = try field(&r, schema: schema, field: f)
            }
            return .object(out)
        }
    }

    private static func field(_ r: inout Reader, schema: Schema, field f: Schema.Field) throws -> Value {
        guard f.isArray else { return try value(&r, schema: schema, type: f.type) }
        let n = try r.varuint()
        var items: [Value] = []
        items.reserveCapacity(min(Int(n), 4096))
        for _ in 0..<n { items.append(try value(&r, schema: schema, type: f.type)) }
        return .array(items)
    }

    // MARK: - Bytes

    struct Reader {
        let bytes: [UInt8]
        var i = 0
        init(_ d: Data) { bytes = [UInt8](d) }

        mutating func byte() throws -> UInt8 {
            guard i < bytes.count else { throw Failure.truncated }
            defer { i += 1 }
            return bytes[i]
        }

        mutating func varuint() throws -> UInt32 {
            var result: UInt32 = 0, shift: UInt32 = 0
            while true {
                let b = try byte()
                if shift < 32 { result |= UInt32(b & 0x7f) << shift }
                shift += 7
                if b & 0x80 == 0 { break }
                if shift > 35 { throw Failure.truncated }
            }
            return result
        }

        mutating func varint() throws -> Int32 {
            let n = try varuint()
            // Zigzag: the sign rides in the low bit so small negatives stay small.
            return Int32(bitPattern: (n >> 1) ^ (~(n & 1) &+ 1))
        }

        mutating func varuint64() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                let b = try byte()
                if shift < 64 { result |= UInt64(b & 0x7f) << shift }
                shift += 7
                if b & 0x80 == 0 { break }
                if shift > 70 { throw Failure.truncated }
            }
            return result
        }

        mutating func varint64() throws -> Int64 {
            let n = try varuint64()
            return Int64(bitPattern: (n >> 1) ^ (~(n & 1) &+ 1))
        }

        /// Kiwi rotates a float's bits so that zero — much the commonest value in
        /// a document full of coordinates — costs one byte instead of four.
        mutating func float() throws -> Float {
            let first = try byte()
            if first == 0 { return 0 }
            let b1 = try byte(), b2 = try byte(), b3 = try byte()
            var bits = UInt32(first) | UInt32(b1) << 8 | UInt32(b2) << 16 | UInt32(b3) << 24
            bits = (bits << 23) | (bits >> 9)
            return Float(bitPattern: bits)
        }

        mutating func string() throws -> String {
            var out: [UInt8] = []
            while true {
                let b = try byte()
                if b == 0 { break }
                out.append(b)
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
}
