import Foundation
import Testing
@testable import SkechworksCore

// The vendored decompressor, on a frame made by the reference encoder.
//
// Kept as bytes rather than compressed here, because nothing in this app can
// write zstd — only read it — and a test that round-trips through our own code
// would prove nothing about whether we agree with Figma's.

private let frame = Data(base64Encoded: "KLUv/SRU/QEAAgQNEbDr4CHybHnIQm0TvKL1jFkEIRiY/VNE6+OPbKkqNok4XQ6jTedvQm1FGX/Tx03mTPSkCAIAruQYMAUFdDXtiA==")!
private let expected = "Figma writes its documents with Kiwi and compresses them with zstd. 0000000000000000"

@Test func aRealZstdFrameDecompresses() throws {
    let out = try #require(FigFile.unzstd(frame))
    #expect(String(decoding: out, as: UTF8.self) == expected)
}

@Test func rubbishComesBackAsNothingRatherThanNoise() {
    // Zstd reports failure as an enormous unsigned size. Read as a signed count
    // that becomes a negative length, and worse, a plausible one.
    #expect(FigFile.unzstd(Data([0x28, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0])) == nil)
    #expect(FigFile.unzstd(Data("not compressed at all".utf8)) == nil)
}

@Test func aFigmaFileIsRecognisedByItsChunks() throws {
    // The container half, without needing a real document: a header and one
    // deflated chunk is not a document, and should say so rather than crash.
    var d = Data("fig-kiwi".utf8)
    d.append(contentsOf: [0, 0, 0, 0])
    #expect(throws: (any Error).self) { try FigFile.unpack(data: d) }
}
