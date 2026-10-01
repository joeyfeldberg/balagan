// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Balagan",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "BalaganCore",
            targets: ["BalaganCore"]
        ),
        .executable(
            name: "BalaganApp",
            targets: ["BalaganApp"]
        ),
        .executable(
            name: "BalaganUIDriver",
            targets: ["BalaganUIDriver"]
        ),
        .executable(
            name: "balagan-agent",
            targets: ["BalaganAgentWrapper"]
        ),
        .executable(
            name: "balagan",
            targets: ["BalaganCLI"]
        ),
    ],
    targets: [
        .target(
            name: "CGhosttyShim"
        ),
        .target(
            name: "BalaganCore",
            dependencies: ["CGhosttyShim"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "BalaganApp",
            dependencies: ["BalaganCore"],
            resources: [.copy("Resources/AppIcon.png")]
        ),
        .executableTarget(
            name: "BalaganUIDriver",
            dependencies: ["BalaganCore"]
        ),
        .executableTarget(
            name: "BalaganAgentWrapper",
            dependencies: ["BalaganCore"]
        ),
        .executableTarget(
            name: "BalaganCLI",
            dependencies: ["BalaganCore"]
        ),
        .testTarget(
            name: "BalaganCoreTests",
            dependencies: ["BalaganCore"]
        ),
        .testTarget(
            name: "BalaganAppTests",
            dependencies: ["BalaganApp", "BalaganCore"]
        ),
    ]
)
