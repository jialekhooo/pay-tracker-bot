// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HowMuchCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "HowMuchCore", targets: ["HowMuchCore"])],
    targets: [.target(name: "HowMuchCore"), .testTarget(name: "HowMuchCoreTests", dependencies: ["HowMuchCore"])]
)
