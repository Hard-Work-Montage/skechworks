// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "skechworks",
    platforms: [.macOS(.v13)],   // .v13 is the floor: CGPath boolean ops land here
    products: [
        .library(name: "SkechworksCore", targets: ["SkechworksCore"]),
        .executable(name: "sw", targets: ["sw"]),
    ],
    targets: [
        // zstd, decompression only. Figma compresses a .fig's document chunk
        // with it and macOS has no zstd — Compression offers zlib, lzma, lz4,
        // brotli and lzfse and stops — so the decompressor travels with us.
        // Upstream sources, unmodified, from the 1.5.6 release; see the LICENCE
        // beside them.
        .target(
            name: "CZstd",
            cSettings: [
                .headerSearchPath("lib"),
                .headerSearchPath("lib/common"),
                // The x86 assembly fast path isn't carried; the C decoder does
                // the same work and this is not a hot path.
                .define("ZSTD_DISABLE_ASM", to: "1"),
                // Nothing here writes a .fig, so the encoder is left out entirely.
                .define("ZSTD_LIB_COMPRESSION", to: "0"),
                .define("ZSTD_LIB_DICTBUILDER", to: "0"),
            ]
        ),
        .target(name: "SkechworksCore", dependencies: ["CZstd"]),
        .executableTarget(name: "sw", dependencies: ["SkechworksCore"]),
        .testTarget(name: "SkechworksCoreTests", dependencies: ["SkechworksCore"]),
    ]
)
