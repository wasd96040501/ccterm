// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AgentSDK",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentSDK", targets: ["AgentSDK"]),
        .library(name: "RemoteEgress", targets: ["RemoteEgress"]),
    ],
    targets: [
        .target(
            name: "AgentSDK"
        ),
        // Native CONNECT forward proxy for the "CCTerm runs one" egress mode.
        // Deliberately separate from AgentSDK: the protocol wrapper must stay
        // transport-agnostic and never learn about ssh/proxy (design §3).
        .target(
            name: "RemoteEgress"
        ),
        .executableTarget(
            name: "RemoteEgressSmoke",
            dependencies: ["RemoteEgress"]
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
            name: "PartialMessagesSmoke",
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
        .executableTarget(
            name: "ThinkingUsageSmoke",
            dependencies: ["AgentSDK"]
        ),
        .executableTarget(
            name: "SideQuestionSmoke",
            dependencies: ["AgentSDK"]
        ),
    ]
)
