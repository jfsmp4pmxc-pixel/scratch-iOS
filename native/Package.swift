// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "ScratchCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ScratchCore", targets: ["ScratchCore"])
    ],
    targets: [
        .target(name: "ScratchCore"),
        .testTarget(name: "ScratchCoreTests", dependencies: ["ScratchCore"])
    ]
)
