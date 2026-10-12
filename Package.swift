// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PeoplemapsCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "PeoplemapsCore", targets: ["PeoplemapsCore"]), .executable(name: "peoplemaps-audit", targets: ["RouteAudit"])],
    targets: [
        .target(name: "PeoplemapsCore", path: "Core", resources: [.process("Resources")]),
        .executableTarget(name: "RouteAudit", dependencies: ["PeoplemapsCore"], path: "Tools"),
        .testTarget(name: "PeoplemapsCoreTests", dependencies: ["PeoplemapsCore"], path: "Tests")
    ]
)
