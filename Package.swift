// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "agentshot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentshot", targets: ["agentshot"]),
        .library(name: "AgentshotCore", targets: ["AgentshotCore"])
    ],
    targets: [
        .target(name: "AgentshotCore"),
        .executableTarget(
            name: "agentshot",
            dependencies: ["AgentshotCore"]
        ),
        .testTarget(
            name: "AgentshotCoreTests",
            dependencies: ["AgentshotCore"]
        )
    ]
)
