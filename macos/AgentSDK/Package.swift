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
        .testTarget(name: "AgentSDKTests", dependencies: ["AgentSDK"]),
    ]
)
