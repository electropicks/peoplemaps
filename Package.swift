// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PeoplemapsCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "PeoplemapsCore", targets: ["PeoplemapsCore"]), .executable(name: "peoplemaps-audit", targets: ["RouteAudit"])],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib", providers: [.apt(["zlib1g-dev"])]),
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "PeoplemapsCore", dependencies: ["CZlib", "CSQLite"], path: "Core", resources: [.process("Resources")]),
        .executableTarget(name: "RouteAudit", dependencies: ["PeoplemapsCore"], path: "Tools"),
        .testTarget(name: "PeoplemapsCoreTests", dependencies: ["PeoplemapsCore"], path: "Tests")
    ]
)
