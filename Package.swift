// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentIsland",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "AgentIslandCore",
            targets: ["AgentIslandCore"]
        ),
        .executable(
            name: "AgentIslandHooks",
            targets: ["AgentIslandHooks"]
        ),
        .executable(
            name: "AgentIslandSetup",
            targets: ["AgentIslandSetup"]
        ),
        .executable(
            name: "AgentIslandApp",
            targets: ["AgentIslandApp"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(
            url: "https://github.com/brayantdeleon/SwiftMath.git",
            revision: "ed1264fafd5ca2b3d0c27af4da7f0dd22cb491f2"
        ),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .target(
            name: "AgentIslandCore"
        ),
        .executableTarget(
            name: "AgentIslandHooks",
            dependencies: ["AgentIslandCore"]
        ),
        .executableTarget(
            name: "AgentIslandSetup",
            dependencies: ["AgentIslandCore"]
        ),
        .executableTarget(
            name: "AgentIslandApp",
            dependencies: [
                "AgentIslandCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "SwiftMath", package: "SwiftMath"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "AgentIslandCoreTests",
            dependencies: ["AgentIslandCore"]
        ),
        .testTarget(
            name: "AgentIslandAppTests",
            dependencies: ["AgentIslandApp", "AgentIslandCore"]
        ),
    ]
)
