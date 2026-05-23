// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AgentSDK",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentSDK", targets: ["AgentSDK"]),
    ],
    targets: [
        .target(
            name: "AgentSDK"
        ),
        .executableTarget(
            name: "SmokeTest",
            dependencies: ["AgentSDK"]
        ),
        .executableTarget(
            name: "DumpSmoke",
            dependencies: ["AgentSDK"]
        ),
        .executableTarget(
            name: "InterruptSmoke",
            dependencies: ["AgentSDK"]
        ),
        .executableTarget(
            name: "PermissionModeProbe",
            dependencies: ["AgentSDK"]
        ),
        .executableTarget(
            name: "QueueTimingSmoke",
            dependencies: ["AgentSDK"]
        ),
        .executableTarget(
            name: "TodoSmoke",
            dependencies: ["AgentSDK"]
        ),
        .executableTarget(
            name: "ContextUsageSmoke",
            dependencies: ["AgentSDK"]
        ),
    ]
)
