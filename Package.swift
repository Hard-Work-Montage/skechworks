// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "accomplice",
    platforms: [.macOS(.v13)],   // .v13 is the floor: CGPath boolean ops land here
    products: [
        .library(name: "AccompliceCore", targets: ["AccompliceCore"]),
        .executable(name: "acmplc", targets: ["acmplc"]),
    ],
    targets: [
        .target(name: "AccompliceCore"),
        .executableTarget(name: "acmplc", dependencies: ["AccompliceCore"]),
        .testTarget(name: "AccompliceCoreTests", dependencies: ["AccompliceCore"]),
    ]
)
