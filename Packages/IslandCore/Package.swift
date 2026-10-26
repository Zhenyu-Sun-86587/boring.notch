// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IslandCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "IslandCore", targets: ["IslandCore"])],
    targets: [
        .target(name: "IslandCore"),
        .executableTarget(name: "IslandCoreChecks", dependencies: ["IslandCore"], path: "Tests/IslandCoreTests")
    ]
)
