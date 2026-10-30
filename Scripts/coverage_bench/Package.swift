// swift-tools-version: 6.0
// The package name below is the checkout directory's name (SwiftPM identifies path dependencies that way).
import PackageDescription

let package = Package(
    name: "coverage-bench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "bench", dependencies: [.product(name: "PeoplemapsCore", package: "all-seattle-spike-d9e97f")], path: "Sources/bench")]
)
