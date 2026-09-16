// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "ZipRipper",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ZipRipper", targets: ["ZipRipperApp"]), .library(name: "ZipRipperCore", targets: ["ZipRipperCore"])],
    targets: [
        .target(name: "ZipRipperCore", resources: [.process("Resources")], linkerSettings: [.linkedFramework("Metal")]),
        .executableTarget(name: "ZipRipperApp", dependencies: ["ZipRipperCore"], resources: [.process("Resources")]),
        .testTarget(name: "ZipRipperCoreTests", dependencies: ["ZipRipperCore"])
    ]
)
