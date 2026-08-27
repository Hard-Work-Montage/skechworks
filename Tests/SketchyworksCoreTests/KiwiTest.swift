import Foundation
import Testing

@testable import SketchyworksCore

// Reading Kiwi, which is how a .fig can be opened at all.
//
// The file carries its own schema, so this is written against the format rather
// than against Figma's model — the thing that would otherwise go stale every
// time they ship. These tests encode by hand and read back, because the format
// is the contract, not any particular document.

private struct Writer {
    var bytes: [UInt8] = []
    var data: Data { Data(bytes) }

    mutating func byte(_ b: UInt8) { bytes.append(b) }
    mutating func varuint(_ v: UInt32) {
        var n = v
        repeat {
            var b = UInt8(n & 0x7f)
            n >>= 7
            if n != 0 { b |= 0x80 }
            bytes.append(b)
        } while n != 0
    }
    mutating func varint(_ v: Int32) {
        let n = UInt32(bitPattern: v)
        varuint((n << 1) ^ UInt32(bitPattern: v >> 31))
    }
    mutating func string(_ s: String) { bytes += Array(s.utf8); bytes.append(0) }
    mutating func float(_ f: Float) {
        if f == 0 { bytes.append(0); return }
        var bits = f.bitPattern
        bits = (bits >> 23) | (bits << 9)
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((bits >> UInt32(shift)) & 0xff)) }
    }
}

/// A schema with one struct (a point) and one message (a node), by hand.
private func demoSchema() -> Data {
    var w = Writer()
    w.varuint(3)                       // three definitions

    w.string("Vec"); w.byte(1); w.varuint(2)          // STRUCT Vec
    w.string("x"); w.varint(-5); w.byte(0); w.varuint(0)
    w.string("y"); w.varint(-5); w.byte(0); w.varuint(0)

    w.string("Kind"); w.byte(0); w.varuint(2)         // ENUM Kind
    w.string("FRAME"); w.varint(0); w.byte(0); w.varuint(1)
    w.string("TEXT"); w.varint(0); w.byte(0); w.varuint(2)

    w.string("Node"); w.byte(2); w.varuint(5)         // MESSAGE Node
    w.string("name"); w.varint(-6); w.byte(0); w.varuint(1)
    w.string("kind"); w.varint(1); w.byte(0); w.varuint(2)
    w.string("at"); w.varint(0); w.byte(0); w.varuint(3)
    w.string("visible"); w.varint(-1); w.byte(0); w.varuint(4)
    w.string("sizes"); w.varint(-4); w.byte(1); w.varuint(5)
    return w.data
}

@Test func aSchemaIsReadOutOfTheFileItself() throws {
    let s = try Kiwi.schema(from: demoSchema())
    #expect(s.index(of: "Node") == 2)
    #expect(s.index(of: "Vec") == 0)
    #expect(s.index(of: "Nope") == nil)
}

@Test func aMessageComesBackAsATree() throws {
    let schema = try Kiwi.schema(from: demoSchema())
    var w = Writer()
    w.varuint(1); w.string("Cover")            // name
    w.varuint(2); w.varuint(2)                 // kind = TEXT
    w.varuint(3); w.float(12.5); w.float(-3)   // at = Vec struct, both fields in order
    w.varuint(4); w.byte(1)                    // visible
    w.varuint(5); w.varuint(3); w.varuint(10); w.varuint(20); w.varuint(30)
    w.varuint(0)                               // end of message

    let v = try Kiwi.decode(w.data, schema: schema, as: "Node")
    #expect(v["name"]?.text == "Cover")
    // An enum arrives as its NAME, which is the useful half.
    #expect(v["kind"]?.text == "TEXT")
    #expect(v["at"]?["x"]?.number == 12.5)
    #expect(v["at"]?["y"]?.number == -3)
    #expect(v["visible"]?.number == 1)
    #expect(v["sizes"]?.items?.compactMap(\.number) == [10, 20, 30])
}

@Test func aFieldThisSchemaDoesNotKnowEndsTheObjectRatherThanDerailing() throws {
    // The wire says nothing about how long a value is, so an unknown id can't be
    // skipped. Stopping is the only honest answer — reading on would take
    // whatever came next as data.
    let schema = try Kiwi.schema(from: demoSchema())
    var w = Writer()
    w.varuint(1); w.string("Kept")
    w.varuint(77); w.varuint(1)                // a field from a newer Figma
    w.varuint(0)
    let v = try Kiwi.decode(w.data, schema: schema, as: "Node")
    #expect(v["name"]?.text == "Kept", "what came before the unknown field must survive")
}

@Test func zeroCostsOneByteAndStillReadsAsZero() throws {
    // Kiwi rotates a float's bits so zero is a single byte. A document is mostly
    // zeroes, and getting this wrong misreads every coordinate in the file.
    let schema = try Kiwi.schema(from: demoSchema())
    var w = Writer()
    w.varuint(3); w.float(0); w.float(1)
    w.varuint(0)
    let v = try Kiwi.decode(w.data, schema: schema, as: "Node")
    #expect(v["at"]?["x"]?.number == 0)
    #expect(v["at"]?["y"]?.number == 1)
}

@Test func negativeNumbersSurviveTheZigzag() throws {
    var w = Writer()
    w.varint(-1); w.varint(-4096); w.varint(2147483647)
    var r = Kiwi.Reader(w.data)
    #expect(try r.varint() == -1)
    #expect(try r.varint() == -4096)
    #expect(try r.varint() == 2147483647)
}

@Test func aTruncatedFileIsRefusedRatherThanGuessed() {
    let schema = try? Kiwi.schema(from: Data([0x05]))   // says five definitions, has none
    #expect(schema == nil)
}

@Test func somethingThatIsNotAFigmaFileIsSaidSo() {
    #expect(throws: (any Error).self) {
        try FigFile.unpack(data: Data("not a figma file at all".utf8))
    }
}
